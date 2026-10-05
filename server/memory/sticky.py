"""便利贴：它给下一轮自己留的几行字。每个用户一张，覆盖写。"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

import asyncpg

from .config import DEFAULT, MemoryConfig


async def get_sticky(pool: asyncpg.Pool, user_id: UUID) -> str:
    return await pool.fetchval("SELECT text FROM sticky_notes WHERE user_id = $1", user_id) or ""


async def set_sticky(pool: asyncpg.Pool, user_id: UUID, text: str, *, now: datetime | None = None,
                     cfg: MemoryConfig = DEFAULT) -> str:
    text = (text or "").strip()[: cfg.sticky_max_chars]
    await pool.execute(
        """INSERT INTO sticky_notes (user_id, text, updated_at) VALUES ($1, $2, $3)
           ON CONFLICT (user_id) DO UPDATE SET text = EXCLUDED.text, updated_at = EXCLUDED.updated_at""",
        user_id, text, now or datetime.now(timezone.utc))
    return text
