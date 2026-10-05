"""人物卡：一种特殊的记忆（kind='person'），一个人一张。名字不分大小写唯一。不衰减。

结构照之前自用的 App：名字 + 别名 + 是谁（relation）+ 要记得（content，用户写的事实）+ 印象
（impression，它自己的）。每张卡记着谁建的、谁最后改的（user / ai）。

为什么要单独一套：向量按「意思像不像」捞，人名这种短词捞不准。人物卡换个路子——
这句话里出现了哪个名字或别名，那张卡就原样递给大脑。同一段上下文里递过的，
由大脑传 exclude 挡掉；账本卷过之后可以再递。

它（by="ai"）能自己建卡、写印象、加别名，也能补空着的「是谁 / 要记得」；
但用户写过的「是谁 / 要记得」它改不动——关于一个人的事实，作者是用户。
"""
from __future__ import annotations

import random
import re
from datetime import datetime, timezone
from uuid import UUID

import asyncpg

from . import words
from .config import DEFAULT, MemoryConfig
from .embed import Embedder, embed_one
from .models import MEMORY_COLUMNS, Memory, row_to_memory
from .store import embed_text

AUTHORS = ("user", "ai")
_ALIAS_SPLIT = re.compile(r"[,，、/\n]")
_LATIN_WORD = re.compile(r"[a-z0-9 .'\-]+")


def clean_aliases(raw, cfg: MemoryConfig = DEFAULT) -> list[str]:
    """别名可以是列表，也可以是一串用逗号 / 顿号 / 斜杠 / 换行隔开的字。去空、去重、限长限个数。"""
    if isinstance(raw, str):
        raw = _ALIAS_SPLIT.split(raw)
    out: list[str] = []
    for a in raw or []:
        a = str(a).strip()[: cfg.person_name_max]
        if a and a not in out:
            out.append(a)
    return out[: cfg.person_alias_max]


def _field(v: str | None, cfg: MemoryConfig) -> str | None:
    return None if v is None else str(v).strip()[: cfg.person_field_max]


def mentions(keyword: str, text: str) -> int:
    """keyword 在 text 里第一次出现的位置，没出现返回 -1。不分大小写。
    中文按子串；纯英文/数字的词要整词才算（Oak 不能撞上 soak）。"""
    k, t = keyword.lower(), text.lower()
    if _LATIN_WORD.fullmatch(k):
        m = re.search(r"(?<![a-z0-9])" + re.escape(k) + r"(?![a-z0-9])", t)
        return m.start() if m else -1
    return t.find(k)


_SHORT_RELATION = re.compile(r"[一-鿿]{1,4}|[A-Za-z][A-Za-z ]{0,15}")
_KIN = {"妈妈", "爸爸", "哥哥", "姐姐", "弟弟", "妹妹", "爷爷", "奶奶", "姥姥", "姥爷", "外婆", "外公"}


def keywords(p: Memory) -> list[str]:
    """认人的词：名字、别名；「是谁」那栏是短称呼（男朋友、室友、妈妈）的也算（09-27：TA 说「我男朋友」，
    卡名是 Mu，对不上）；妈妈、爸爸这类叠字称呼，「我妈」「我爸」也算。"""
    words_ = [p.name or ""] + list(p.aliases)
    rel = (p.relation or "").strip()
    if rel and _SHORT_RELATION.fullmatch(rel):
        words_.append(rel)
    words_ += ["我" + w[0] for w in list(words_) if w in _KIN]
    return clean_aliases(words_)


async def _write(pool, embedder, user_id: UUID, card_id: int, *, name, aliases, relation, facts,
                 impression, by: str, now: datetime) -> Memory:
    text = embed_text(facts, name, relation, impression)
    vec = await embed_one(embedder, text)
    row = await pool.fetchrow(
        f"""UPDATE memories SET name = $3, aliases = $4, relation = $5, content = $6, impression = $7,
              updated_by = $8, updated_at = $9, embedding = COALESCE($10, embedding),
              search_tsv = to_tsvector('simple', $11)
            WHERE user_id = $1 AND id = $2 AND kind = 'person' RETURNING {MEMORY_COLUMNS}""",
        user_id, card_id, name, aliases, relation, facts, impression, by, now, vec,
        words.search_text(text))
    return row_to_memory(row)


async def upsert_person(
    pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, name: str, *,
    relation: str | None = None, facts: str | None = None, impression: str | None = None,
    aliases=(), by: str = "user", importance: int = 6, now: datetime | None = None,
    cfg: MemoryConfig = DEFAULT,
) -> Memory:
    """按名字找卡：没有就建，有就改。没给的字段不动；别名是往上加。"""
    if by not in AUTHORS:
        raise ValueError(f"by must be user or ai, got {by!r}")
    name = (name or "").strip()[: cfg.person_name_max]
    if not name:
        raise ValueError("name is empty")
    now = now or datetime.now(timezone.utc)
    relation, facts, impression = (_field(v, cfg) for v in (relation, facts, impression))
    aliases = clean_aliases(aliases, cfg)
    existing = await pool.fetchrow(
        f"SELECT {MEMORY_COLUMNS} FROM memories "
        "WHERE user_id = $1 AND kind = 'person' AND lower(name) = lower($2)",
        user_id, name)

    if existing is not None:
        cur = row_to_memory(existing)
        # 它改不动用户写的事实：用户建的卡上，「是谁 / 要记得」已经有字了就保持原样
        locked = by == "ai" and cur.created_by == "user"
        if relation is None or (locked and cur.relation):
            relation = cur.relation
        if facts is None or (locked and cur.content):
            facts = cur.content
        if impression is None:
            impression = cur.impression
        return await _write(
            pool, embedder, user_id, cur.id, name=cur.name,
            aliases=clean_aliases(cur.aliases + aliases, cfg), relation=relation,
            facts=facts, impression=impression, by=by, now=now)

    facts = facts or ""
    impression = impression or ""
    text = embed_text(facts, name, relation, impression)
    vec = await embed_one(embedder, text)
    row = await pool.fetchrow(
        f"""INSERT INTO memories (user_id, kind, content, name, aliases, relation, impression,
                                  created_by, updated_by, importance, created_at, updated_at,
                                  embedding, search_tsv)
            VALUES ($1, 'person', $2, $3, $4, $5, $6, $7, $7, $8, $9, $9, $10,
                    to_tsvector('simple', $11))
            RETURNING {MEMORY_COLUMNS}""",
        user_id, facts, name, aliases, relation, impression, by, max(1, min(10, importance)), now,
        vec, words.search_text(text))
    return row_to_memory(row)


async def update_person(
    pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, person_id: int, *,
    name: str | None = None, aliases=None, relation: str | None = None, facts: str | None = None,
    impression: str | None = None, by: str = "user", now: datetime | None = None,
    cfg: MemoryConfig = DEFAULT,
) -> Memory | None:
    """app 里编辑一张卡：给了的字段整个换掉（别名也是换，不是加），没给的不动。"""
    if by not in AUTHORS:
        raise ValueError(f"by must be user or ai, got {by!r}")
    row = await pool.fetchrow(
        f"SELECT {MEMORY_COLUMNS} FROM memories WHERE user_id = $1 AND id = $2 AND kind = 'person'",
        user_id, person_id)
    if row is None:
        return None
    cur = row_to_memory(row)
    if name is not None:
        name = name.strip()[: cfg.person_name_max]
        if not name:
            raise ValueError("name is empty")
    return await _write(
        pool, embedder, user_id, cur.id,
        name=name if name is not None else cur.name,
        aliases=clean_aliases(aliases, cfg) if aliases is not None else cur.aliases,
        relation=_field(relation, cfg) if relation is not None else cur.relation,
        facts=_field(facts, cfg) if facts is not None else cur.content,
        impression=_field(impression, cfg) if impression is not None else cur.impression,
        by=by, now=now or datetime.now(timezone.utc))


async def list_people(pool: asyncpg.Pool, user_id: UUID) -> list[Memory]:
    rows = await pool.fetch(
        f"SELECT {MEMORY_COLUMNS} FROM memories WHERE user_id = $1 AND kind = 'person' "
        "ORDER BY lower(name)", user_id)
    return [row_to_memory(r) for r in rows]


async def linked_memories(pool: asyncpg.Pool, owner: UUID, person: Memory, *, exclude=frozenset(),
                          before: datetime | None = None, now: datetime | None = None, rng: random.Random | None = None,
                          cfg: MemoryConfig = DEFAULT) -> list[Memory]:
    """跟这个人有关的记忆（正文里提到他的名字、别名或短称呼——认人用的同一套词），
    随机挑几条，越新越容易被挑中（Tilia 09-27 定）。owner = 记忆的主人（联系人）；人物卡本身在账号名下。
    before = 原文还在上下文里的那段开始的时间，之后记的不挑（原话它眼前就有）。"""
    keys = keywords(person)
    if not keys:
        return []
    rows = await pool.fetch(
        f"""SELECT {MEMORY_COLUMNS} FROM memories
            WHERE user_id = $1 AND kind IN ('memory', 'about')
              AND ($3::timestamptz IS NULL OR created_at < $3)
              AND EXISTS (SELECT 1 FROM unnest($2::text[]) k WHERE position(lower(k) in lower(content)) > 0)""",
        owner, keys, before)
    cands = [row_to_memory(r) for r in rows if r["id"] not in exclude]
    cands = [m for m in cands if any(mentions(k, m.content) >= 0 for k in keys)]   # 英文名要整词
    if not cands:
        return []
    now = now or datetime.now(timezone.utc)
    rng = rng or random.Random()
    # 权重 = 1 / (1 + 天数 / 30)：越新越容易挑中，但老的也还有机会（半衰那种曲线 300 天前的千分之一，等于永远想不起来）
    scale = cfg.person_linked_age_scale_days
    picked: list[Memory] = []
    while cands and len(picked) < cfg.person_linked_max:
        weights = [1.0 / (1.0 + max(0.0, (now - m.created_at).total_seconds() / 86400) / scale) for m in cands]
        i = rng.choices(range(len(cands)), weights=weights)[0]
        picked.append(cands.pop(i))
    return picked


async def match_people(pool: asyncpg.Pool, user_id: UUID, text: str, *, exclude=frozenset(),
                       cfg: MemoryConfig = DEFAULT) -> list[Memory]:
    """这句话里提到的、还没递过的卡，按在话里出现的先后，最多 person_match_max 张。"""
    if not (text or "").strip():
        return []
    hits: list[tuple[int, Memory]] = []
    for p in await list_people(pool, user_id):
        if p.id in exclude:
            continue
        spots = [i for i in (mentions(k, text) for k in keywords(p)) if i >= 0]
        if spots:
            hits.append((min(spots), p))
    hits.sort(key=lambda x: x[0])
    return [p for _, p in hits[: cfg.person_match_max]]


_LABELS = {
    "zh": ("〔人物卡 · {head}〕", "（也叫 {aka}）", " / ", "｜", "是谁：", "要记得：", "你的印象："),
    "en": ("[Person card · {head}]", " (aka {aka})", " / ", " | ", "Who: ", "Remember: ", "Your impression: "),
}


def render_person(p: Memory, lang: str = "zh") -> str:
    """递给大脑的那一行。"""
    title, aka_fmt, aka_sep, sep, who, remember, impression = _LABELS.get(lang, _LABELS["zh"])
    alias = [a for a in p.aliases if a != p.name]
    head = (p.name or "") + (aka_fmt.format(aka=aka_sep.join(alias)) if alias else "")
    parts = []
    if p.relation:
        parts.append(who + p.relation)
    if p.content:
        parts.append(remember + p.content)
    if p.impression:
        parts.append(impression + p.impression)
    return title.format(head=head) + (" " if lang == "en" and parts else "") + sep.join(parts)
