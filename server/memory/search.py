"""混合搜索：向量一路 + 关键词一路，按排名融合（RRF），再乘上当前分量。

RRF：每一路里排第 r 名的得 1/(k+r)，两路都靠前的加起来最高——不用管两路分数的尺度对不上。
最终分 = 融合分 × (weight_floor + 当前分量)：同样相关时，新的/重要的/常被想起的排前面，
但老记忆也不会被压到零。
"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

import asyncpg
import numpy as np

from . import stopwords, store, words
from .config import DEFAULT, MemoryConfig
from .decay import weight
from .embed import Embedder, embed_one
from .models import SearchHit

ALL_KINDS = ("memory", "core", "person", "diary")   # diary：Ta 的日记也能翻到（10-01）


def rrf_fuse(rankings: list[list[int]], k: int = 60) -> dict[int, float]:
    fused: dict[int, float] = {}
    for ranking in rankings:
        for rank, mid in enumerate(ranking, start=1):
            fused[mid] = fused.get(mid, 0.0) + 1.0 / (k + rank)
    return fused


async def keyword_ids(pool: asyncpg.Pool, user_id: UUID, text: str, limit: int,
                      kinds=ALL_KINDS, names=()) -> list[int]:
    """names：称呼（它的名字、用户的名字…），连同这个用户库里太常见的词一起不进关键词榜（stopwords.py）。"""
    q = words.tsquery(text, await stopwords.for_user(pool, user_id, names))
    if not q:
        return []
    rows = await pool.fetch(
        """SELECT id FROM memories
           WHERE user_id = $1 AND kind = ANY($2::text[])
             AND search_tsv @@ to_tsquery('simple', $3)
           ORDER BY ts_rank_cd(search_tsv, to_tsquery('simple', $3)) DESC, id DESC
           LIMIT $4""",
        user_id, list(kinds), q, limit)
    return [r["id"] for r in rows]


async def vector_ids(pool: asyncpg.Pool, user_id: UUID, vec: np.ndarray, limit: int,
                     kinds=ALL_KINDS) -> list[tuple[int, float]]:
    rows = await pool.fetch(
        """SELECT id, 1 - (embedding <=> $3) AS sim FROM memories
           WHERE user_id = $1 AND kind = ANY($2::text[]) AND embedding IS NOT NULL
           ORDER BY embedding <=> $3 LIMIT $4""",
        user_id, list(kinds), vec, limit)
    return [(r["id"], float(r["sim"])) for r in rows]


async def search(pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, query: str, *,
                 limit: int = 10, touch: bool = True, now: datetime | None = None,
                 cfg: MemoryConfig = DEFAULT, names=()) -> list[SearchHit]:
    now = now or datetime.now(timezone.utc)
    kw = await keyword_ids(pool, user_id, query, cfg.search_candidates, names=names)
    vec = await embed_one(embedder, query)
    vs = await vector_ids(pool, user_id, vec, cfg.search_candidates) if vec is not None else []
    sims = dict(vs)
    fused = rrf_fuse([[i for i, _ in vs], kw], k=cfg.rrf_k)
    mems = await store.fetch_many(pool, user_id, fused.keys())
    kw_set = set(kw)
    hits = [
        SearchHit(memory=m, score=fused[mid] * (cfg.weight_floor + weight(m, now, cfg)),
                  sim=sims.get(mid), keyword=mid in kw_set)
        for mid, m in mems.items()
    ]
    hits.sort(key=lambda h: h.score, reverse=True)
    hits = hits[:limit]
    if touch and hits:
        await store.touch(pool, user_id, [h.memory.id for h in hits], now)
    return hits
