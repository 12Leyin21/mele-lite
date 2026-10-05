"""里程碑（10-05 上服务器；Lite 早有）：它觉得这一刻值得记住——第一次一起做的事、说好的约定——就立一座。
TA 在 Record 的大事记里看（GET /milestones）。同一个联系人同一句话一天内只立一次。"""
from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID

TITLE_MAX = 60
SAME_WITHIN = timedelta(days=1)


async def add(pool, account: UUID, companion: UUID, title: str, *, now: datetime) -> int | None:
    """立一座，返回编号；一天内立过同一句返回 None。"""
    title = " ".join((title or "").split())[:TITLE_MAX]
    if not title:
        raise ValueError("要写一句标题")
    dup = await pool.fetchval("SELECT 1 FROM milestones WHERE companion_id = $1 AND title = $2 AND created_at > $3",
                              companion, title, now - SAME_WITHIN)
    if dup:
        return None
    return await pool.fetchval("INSERT INTO milestones (account_id, companion_id, title, created_at) VALUES ($1, $2, $3, $4) "
                               "RETURNING id", account, companion, title, now)


async def list_all(pool, account: UUID) -> list[dict]:
    rows = await pool.fetch("SELECT id, companion_id, title, created_at FROM milestones WHERE account_id = $1 "
                            "ORDER BY created_at, id", account)
    return [{"id": r["id"], "companion_id": str(r["companion_id"]), "title": r["title"], "at": r["created_at"].isoformat()}
            for r in rows]
