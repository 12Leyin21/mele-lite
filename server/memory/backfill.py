"""补向量：存的时候模型挂了的记忆，后台定时补上。这是后台工作，跨所有用户扫——
但只写回各自那一行，不读也不返回任何正文给调用方。"""
from __future__ import annotations

import asyncio
import logging

import asyncpg

from .embed import Embedder
from .store import embed_text

log = logging.getLogger(__name__)


async def backfill(pool: asyncpg.Pool, embedder: Embedder, limit: int = 100) -> int:
    rows = await pool.fetch(
        "SELECT id, content, name, relation, impression FROM memories WHERE embedding IS NULL ORDER BY id LIMIT $1",
        limit)
    if not rows:
        return 0
    texts = [embed_text(r["content"], r["name"], r["relation"], r["impression"]) for r in rows]
    try:
        vecs = await asyncio.to_thread(embedder.embed, texts)
    except Exception:
        log.exception("backfill embedding failed")
        return 0
    async with pool.acquire() as conn:
        async with conn.transaction():
            for r, v in zip(rows, vecs):
                await conn.execute("UPDATE memories SET embedding = $2 WHERE id = $1", r["id"], v)
    return len(rows)
