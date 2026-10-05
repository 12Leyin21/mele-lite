"""倒回用的记账和撤回（2026-09-27 Tilia定：倒回时，那几轮里它记下或改过的东西一起撤回，
不然会出现「它记得一件在它那边从没发生过的事」）。"""
from __future__ import annotations

import json
from datetime import datetime
import logging
from dataclasses import dataclass
from uuid import UUID

import memory as M

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class EditRef:
    conversation: UUID
    turn_msg: int          # 这一轮用户那句的消息 id


def memory_snapshot(m) -> dict:
    return {"content": m.content, "importance": m.importance, "tags": list(m.tags),
            "valence": m.valence, "arousal": m.arousal}


def person_snapshot(p) -> dict:
    return {"impression": p.impression, "aliases": list(p.aliases), "relation": p.relation}


def lore_snapshot(e) -> dict:
    return {"name": e.name, "keywords": list(e.keywords), "content": e.content, "enabled": e.enabled,
            "companion_id": str(e.companion_id) if e.companion_id else None}


async def record(pool, ref: EditRef | None, kind: str, owner: UUID, memory_id: int | None, before: dict | str | None):
    if ref is None:
        return
    await pool.execute(
        "INSERT INTO memory_edits (conversation_id, turn_msg, kind, owner, memory_id, before) VALUES ($1,$2,$3,$4,$5,$6)",
        ref.conversation, ref.turn_msg, kind, owner, memory_id,
        None if before is None else json.dumps(before, ensure_ascii=False))


async def forget_up_to(pool, conversation: UUID, last_rolled_msg: int) -> None:
    """卷进账本的那段倒不回去了，它们的记账留着没用：卷账本时顺手清掉，免得越攒越多。"""
    await pool.execute("DELETE FROM memory_edits WHERE conversation_id = $1 AND turn_msg <= $2",
                       conversation, last_rolled_msg)


async def _undo_far_date(pool, companion: UUID, date_id: int, before: dict | None) -> None:
    from datetime import date, timezone
    from . import archive
    from . import far_dates as FD
    from .settings import Settings
    acc = await pool.fetchval("SELECT account_id FROM far_dates WHERE id = $1 AND companion_id = $2", date_id, companion)
    if acc is None:
        return
    if before is None:
        await FD.delete(pool, acc, date_id)
        return
    s = Settings.from_dict(await archive.get_settings(pool, companion))
    await FD.update(pool, acc, date_id, s, day=date.fromisoformat(before["day"]), at_time=before["at_time"],
                    title=before["title"], note=before["note"], now=datetime.now(timezone.utc))


async def undo(pool, embedder, conversation: UUID, from_turn_msg: int) -> int:
    """撤回这个窗口里从 from_turn_msg 那一轮起的所有改动，最新的先撤。返回撤了几笔。"""
    rows = await pool.fetch(
        "SELECT * FROM memory_edits WHERE conversation_id = $1 AND turn_msg >= $2 ORDER BY id DESC",
        conversation, from_turn_msg)
    for r in rows:
        before = json.loads(r["before"]) if r["before"] is not None else None
        try:
            if r["kind"] == "clock":           # 钟：新定的删掉，取消的按原样放回去（编号会变，没关系）
                if before is None:
                    await pool.execute("DELETE FROM clocks WHERE id = $1 AND companion_id = $2", r["memory_id"], r["owner"])
                else:
                    await pool.execute(
                        """INSERT INTO clocks (account_id, companion_id, kind, shape, spec, note, next_at)
                           SELECT account_id, id, $2, $3, $4::jsonb, $5, $6::timestamptz FROM companions WHERE id = $1""",
                        r["owner"], before["kind"], before["shape"], json.dumps(before["spec"]), before["note"],
                        datetime.fromisoformat(before["next_at"]) if before["next_at"] else None)
            elif r["kind"] == "far_date":      # 远事：新记的删掉（连钟）；改过的改回去、重排
                await _undo_far_date(pool, r["owner"], r["memory_id"], before)
            elif r["kind"] == "todo":          # 待办：它新加的删掉（owner = 账号）
                await pool.execute("DELETE FROM todos WHERE id = $1 AND account_id = $2", r["memory_id"], r["owner"])
            elif r["kind"] == "drawer":        # 抽屉：新放的信拿走（给钥匙、烧掉不撤）
                await pool.execute("DELETE FROM drawer_letters WHERE id = $1 AND companion_id = $2",
                                   r["memory_id"], r["owner"])
            elif r["kind"] == "milestone":     # 里程碑：新立的拿掉（owner = 联系人）
                await pool.execute("DELETE FROM milestones WHERE id = $1 AND companion_id = $2", r["memory_id"], r["owner"])
            elif r["kind"] == "lore":          # 世界书：新记的删掉，改过的改回去（owner = 账号）
                from . import lore
                if before is None:
                    await lore.delete(pool, r["owner"], r["memory_id"])
                else:
                    await lore.update(pool, r["owner"], r["memory_id"], name=before["name"], keywords=before["keywords"],
                                      content=before["content"], enabled=before["enabled"],
                                      companion_id=UUID(before["companion_id"]) if before["companion_id"] else None)
            elif r["kind"] == "sticky":
                await M.set_sticky(pool, r["owner"], before or "")
            elif before is None:
                await M.delete(pool, r["owner"], r["memory_id"])
            elif r["kind"] == "person":
                await M.update_person(pool, embedder, r["owner"], r["memory_id"], impression=before["impression"],
                                      aliases=before["aliases"], relation=before["relation"], by="ai")
            else:
                await M.update(pool, embedder, r["owner"], r["memory_id"], **before)
        except Exception:
            log.exception("undo edit %s failed", r["id"])
    await pool.execute("DELETE FROM memory_edits WHERE conversation_id = $1 AND turn_msg >= $2",
                       conversation, from_turn_msg)
    return len(rows)
