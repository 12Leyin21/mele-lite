"""记忆的增删改查。所有 SQL 的 WHERE 都带 user_id——别的用户的记忆在这一层就不可见。"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

import asyncpg

from . import words
from .config import DEFAULT, MemoryConfig
from .embed import Embedder, embed_one
from .models import HIDDEN_KINDS, KINDS, MEMORY_COLUMNS, Memory, RememberResult, row_to_memory


def _now(now: datetime | None) -> datetime:
    return now or datetime.now(timezone.utc)


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def embed_text(content: str, name: str | None = None, relation: str | None = None,
               impression: str | None = None) -> str:
    """算向量 / 分词用的文本。人物卡把名字、是谁、印象也带上。"""
    head = " ".join(x for x in (name, relation) if x)
    body = " ".join(x for x in (content, impression) if x)
    return f"{head}：{body}" if head else body


async def remember(
    pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, content: str, *,
    importance: int = 5, tags=(), valence: float = 0.0, arousal: float = 0.0,
    kind: str = "memory", resolved: bool = False, now: datetime | None = None,
    cfg: MemoryConfig = DEFAULT,
) -> RememberResult:
    content = (content or "").strip()
    if not content:
        raise ValueError("content is empty")
    if kind not in ("memory", "core", "about", "diary"):
        raise ValueError(f"kind must be memory, core, about or diary (people go through people.upsert_person), got {kind!r}")
    now = _now(now)
    importance = int(_clamp(importance, 1, 10))
    valence = _clamp(valence, -1.0, 1.0)
    arousal = _clamp(arousal, 0.0, 1.0)
    tags = list(dict.fromkeys(t.strip() for t in tags if t and t.strip()))
    vec = await embed_one(embedder, content)
    tsv_text = words.search_text(content)

    if vec is not None and kind != "diary":          # 日记一天一篇，再像也不合并（10-01）
        near = await pool.fetchrow(
            "SELECT id, 1 - (embedding <=> $3) AS sim FROM memories "
            "WHERE user_id = $1 AND kind = $2 AND embedding IS NOT NULL "
            "ORDER BY embedding <=> $3 LIMIT 1",
            user_id, kind, vec,
        )
        if near is not None and float(near["sim"]) >= cfg.merge_threshold:
            row = await pool.fetchrow(
                f"""UPDATE memories SET
                      content = $3,
                      importance = GREATEST(importance, $4),
                      tags = ARRAY(SELECT DISTINCT unnest(tags || $5::text[])),
                      valence = $6,
                      arousal = GREATEST(arousal, $7),
                      recall_count = recall_count + 1,
                      updated_at = $8,
                      rewritten_at = $8,
                      embedding = $9,
                      search_tsv = to_tsvector('simple', $10)
                    WHERE user_id = $1 AND id = $2
                    RETURNING {MEMORY_COLUMNS}""",
                user_id, near["id"], content, importance, tags, valence, arousal, now, vec, tsv_text,
            )
            return RememberResult(row_to_memory(row), merged=True)

    row = await pool.fetchrow(
        f"""INSERT INTO memories
              (user_id, kind, content, importance, valence, arousal, tags, resolved,
               created_at, updated_at, embedding, search_tsv)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9, $10, to_tsvector('simple', $11))
            RETURNING {MEMORY_COLUMNS}""",
        user_id, kind, content, importance, valence, arousal, tags, resolved, now, vec, tsv_text,
    )
    return RememberResult(row_to_memory(row), merged=False)


async def nearest(pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, content: str, *,
                  kinds=("memory", "about")) -> tuple[Memory, float] | None:
    """这句话跟哪条已有记忆最像、像多少（余弦相似度）。向量算不出来或者还没有记忆就返回 None。"""
    vec = await embed_one(embedder, content)
    if vec is None:
        return None
    row = await pool.fetchrow(
        f"""SELECT {MEMORY_COLUMNS}, 1 - (embedding <=> $3) AS sim FROM memories
            WHERE user_id = $1 AND kind = ANY($2::text[]) AND embedding IS NOT NULL
            ORDER BY embedding <=> $3 LIMIT 1""",
        user_id, list(kinds), vec)
    return (row_to_memory(row), float(row["sim"])) if row else None


async def near_duplicate(pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, content: str, *,
                         kinds=("memory", "about"), cfg: MemoryConfig = DEFAULT) -> tuple[Memory, float, list[str]] | None:
    """存之前查重（大脑的「记住」用）：返回 (最像的那条, 相似度, 共用的少见词) 或 None。
    两种算像：① 相似度到 similar_guard；② 到 rare_guard_sim，并且共用一个在别的记忆里几乎不出现的词。
    只看相似度分不开真假（09-27：「搬去墨尔本」和「读护理」0.733，比真重复的星际穿越 0.674 还高），
    少见的词是第二个信号——同一件事总会提到同一个专有的东西。自动合并线以上的不管（remember 自己会并）。"""
    vec = await embed_one(embedder, content)
    if vec is None:
        return None
    rows = await pool.fetch(
        f"""SELECT {MEMORY_COLUMNS}, 1 - (embedding <=> $3) AS sim FROM memories
            WHERE user_id = $1 AND kind = ANY($2::text[]) AND embedding IS NOT NULL
            ORDER BY embedding <=> $3 LIMIT 5""", user_id, list(kinds), vec)
    rows = [r for r in rows if float(r["sim"]) < cfg.merge_threshold]
    if rows and float(rows[0]["sim"]) >= cfg.similar_guard:
        return row_to_memory(rows[0]), float(rows[0]["sim"]), []
    mine = {t for t in words.tokens(content) if len(t) >= 2}
    for r in rows:
        if float(r["sim"]) < cfg.rare_guard_sim:
            break
        rare = []
        for t in sorted(mine & {t for t in words.tokens(r["content"]) if len(t) >= 2}):
            df = await pool.fetchval(
                "SELECT count(*) FROM memories WHERE user_id = $1 AND kind = ANY($2::text[]) "
                "AND search_tsv @@ to_tsquery('simple', $3)", user_id, list(kinds), t)
            if df <= cfg.rare_max_df:
                rare.append(t)
        if rare:
            return row_to_memory(r), float(r["sim"]), rare
    return None


async def get(pool: asyncpg.Pool, user_id: UUID, memory_id: int) -> Memory | None:
    row = await pool.fetchrow(
        f"SELECT {MEMORY_COLUMNS} FROM memories WHERE user_id = $1 AND id = $2", user_id, memory_id)
    return row_to_memory(row) if row else None


async def fetch_many(pool: asyncpg.Pool, user_id: UUID, ids) -> dict[int, Memory]:
    ids = [int(i) for i in ids]
    if not ids:
        return {}
    rows = await pool.fetch(
        f"SELECT {MEMORY_COLUMNS} FROM memories WHERE user_id = $1 AND id = ANY($2::bigint[])",
        user_id, ids)
    return {r["id"]: row_to_memory(r) for r in rows}


async def update(
    pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, memory_id: int, *,
    content: str | None = None, importance: int | None = None, tags=None,
    valence: float | None = None, arousal: float | None = None, now: datetime | None = None,
) -> Memory | None:
    current = await get(pool, user_id, memory_id)
    if current is None:
        return None
    new_content = (content or "").strip() or current.content
    vec_changed = new_content != current.content
    vec = await embed_one(embedder, embed_text(new_content, current.name, current.relation, current.impression)) if vec_changed else None
    row = await pool.fetchrow(
        f"""UPDATE memories SET
              content = $3,
              importance = $4,
              tags = $5,
              valence = $6,
              arousal = $7,
              updated_at = $8,
              rewritten_at = CASE WHEN $9 THEN $8 ELSE rewritten_at END,
              embedding = CASE WHEN $9 THEN $10 ELSE embedding END,
              search_tsv = to_tsvector('simple', $11)
            WHERE user_id = $1 AND id = $2
            RETURNING {MEMORY_COLUMNS}""",
        user_id, memory_id, new_content,
        int(_clamp(importance, 1, 10)) if importance is not None else current.importance,
        list(tags) if tags is not None else current.tags,
        _clamp(valence, -1.0, 1.0) if valence is not None else current.valence,
        _clamp(arousal, 0.0, 1.0) if arousal is not None else current.arousal,
        _now(now), vec_changed, vec,
        words.search_text(embed_text(new_content, current.name, current.relation, current.impression)),
    )
    return row_to_memory(row) if row else None


async def pin(pool: asyncpg.Pool, user_id: UUID, memory_id: int, pinned: bool = True) -> Memory | None:
    row = await pool.fetchrow(
        f"""UPDATE memories SET kind = $3 WHERE user_id = $1 AND id = $2 AND kind <> 'person'
            RETURNING {MEMORY_COLUMNS}""",
        user_id, memory_id, "core" if pinned else "memory")
    return row_to_memory(row) if row else None


async def resolve(pool: asyncpg.Pool, user_id: UUID, memory_id: int, resolved: bool = True) -> Memory | None:
    row = await pool.fetchrow(
        f"UPDATE memories SET resolved = $3 WHERE user_id = $1 AND id = $2 RETURNING {MEMORY_COLUMNS}",
        user_id, memory_id, resolved)
    return row_to_memory(row) if row else None


async def delete(pool: asyncpg.Pool, user_id: UUID, memory_id: int) -> bool:
    status = await pool.execute("DELETE FROM memories WHERE user_id = $1 AND id = $2", user_id, memory_id)
    return status.endswith(" 1")


async def list_memories(
    pool: asyncpg.Pool, user_id: UUID, *, kind: str | None = None, limit: int = 200, offset: int = 0,
    include_hidden: bool = False,
) -> list[Memory]:
    """给 app「它记得的」页面。不指定 kind 时不含看不见的类（关于 TA），除非 include_hidden。"""
    if kind is not None and kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}")
    hidden = [] if include_hidden or kind is not None else list(HIDDEN_KINDS)
    rows = await pool.fetch(
        f"""SELECT {MEMORY_COLUMNS} FROM memories
            WHERE user_id = $1 AND ($2::text IS NULL OR kind = $2) AND NOT (kind = ANY($5::text[]))
            ORDER BY created_at DESC, id DESC LIMIT $3 OFFSET $4""",
        user_id, kind, limit, offset, hidden)
    return [row_to_memory(r) for r in rows]


async def touch(pool: asyncpg.Pool, user_id: UUID, ids, now: datetime) -> None:
    ids = [int(i) for i in ids]
    if not ids:
        return
    await pool.execute(
        "UPDATE memories SET last_recalled_at = $3, recall_count = recall_count + 1 "
        "WHERE user_id = $1 AND id = ANY($2::bigint[])",
        user_id, ids, now)


async def export(pool: asyncpg.Pool, user_id: UUID) -> dict:
    rows = await pool.fetch(
        f"SELECT {MEMORY_COLUMNS} FROM memories WHERE user_id = $1 ORDER BY id", user_id)
    sticky = await pool.fetchval("SELECT text FROM sticky_notes WHERE user_id = $1", user_id)
    return {"memories": [row_to_memory(r).to_dict() for r in rows], "sticky": sticky or ""}


async def wipe(pool: asyncpg.Pool, user_id: UUID) -> int:
    async with pool.acquire() as conn:
        async with conn.transaction():
            status = await conn.execute("DELETE FROM memories WHERE user_id = $1", user_id)
            await conn.execute("DELETE FROM sticky_notes WHERE user_id = $1", user_id)
    return int(status.split()[-1])
