"""收藏夹（10-02，移植自之前自用的 App FavoritesStore）：长按一个气泡「收藏」，多选「收藏 n 条为一组」。

之前自用的 App存在手机上；Mele 存服务器（换手机、重装都在）。原话整个存一份，窗口删了、倒回了也不丢——
跳回原位时窗口没了就跳不回去，收藏照样能看。无痕窗口不给收（它本来就不留）。"""
from __future__ import annotations

import json
from datetime import datetime
from uuid import UUID, uuid4

from . import attachments

MAX_TEXT = 4000
MAX_GROUP = 200


class FavoriteError(ValueError):
    pass


def _row(r) -> dict:
    return {"id": r["id"], "companion_id": str(r["companion_id"]), "conversation_id": str(r["conversation_id"]),
            "message_id": r["message_id"], "slot": r["slot"], "mine": r["mine"], "text": r["text"],
            "files": json.loads(r["files"]) if isinstance(r["files"], str) else r["files"],
            "group_id": str(r["group_id"]) if r["group_id"] else None,
            "said_at": r["said_at"].isoformat(), "saved_at": r["saved_at"].isoformat()}


_COLS = "id, companion_id, conversation_id, message_id, slot, mine, text, files, group_id, said_at, saved_at"


async def list_all(pool, account: UUID) -> list[dict]:
    rows = await pool.fetch(f"SELECT {_COLS} FROM favorites WHERE account_id = $1 ORDER BY saved_at DESC, message_id, slot",
                            account)
    return [_row(r) for r in rows]


async def add(pool, account: UUID, items: list[dict], *, group: bool, now: datetime) -> list[dict]:
    """items = [{message_id, slot, text, with_files?}]。消息必须是这个账号的、不在无痕窗口里；收过的跳过。
    group = 多选那种，收成一组（同组里收过的不再收，剩下的还是一组）。"""
    if not items:
        raise FavoriteError("要收哪句？")
    if len(items) > MAX_GROUP:
        raise FavoriteError(f"一次最多收 {MAX_GROUP} 条")
    try:
        ids = [int(i["message_id"]) for i in items]
        slots = [int(i.get("slot", 0)) for i in items]
    except (KeyError, TypeError, ValueError):
        raise FavoriteError("每条要带 message_id") from None
    rows = {r["id"]: r for r in await pool.fetch(
        "SELECT m.id, m.user_id AS conv, m.role, m.created_at, c.companion_id, c.incognito "
        "FROM chat_messages m JOIN conversations c ON c.id = m.user_id "
        "WHERE m.id = ANY($1::bigint[]) AND c.account_id = $2", ids, account)}
    if any(i not in rows for i in ids):
        raise FavoriteError("没有这句")
    if any(rows[i]["incognito"] for i in ids):
        raise FavoriteError("无痕窗口里的话不收藏")
    files = await attachments.for_messages(pool, ids)
    gid = uuid4() if group and len(items) > 1 else None
    out = []
    async with pool.acquire() as con, con.transaction():
        for item, mid, slot in sorted(zip(items, ids, slots), key=lambda t: (t[1], t[2])):
            r = rows[mid]
            fs = [f.public() for f in files.get(mid, [])] if item.get("with_files") else []
            got = await con.fetchrow(
                f"INSERT INTO favorites (account_id, companion_id, conversation_id, message_id, slot, mine, text, files, "
                f"group_id, said_at, saved_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11) "
                f"ON CONFLICT (account_id, message_id, slot) DO NOTHING RETURNING {_COLS}",
                account, r["companion_id"], r["conv"], mid, slot, r["role"] == "user",
                str(item.get("text") or "")[:MAX_TEXT], json.dumps(fs, ensure_ascii=False), gid, r["created_at"], now)
            if got:
                out.append(_row(got))
    return out


async def remove(pool, account: UUID, fid: int) -> bool:
    return (await pool.execute("DELETE FROM favorites WHERE account_id = $1 AND id = $2", account, fid)) != "DELETE 0"


async def remove_bubble(pool, account: UUID, message_id: int, slot: int) -> bool:
    return (await pool.execute("DELETE FROM favorites WHERE account_id = $1 AND message_id = $2 AND slot = $3",
                               account, message_id, slot)) != "DELETE 0"


async def remove_group(pool, account: UUID, group_id: UUID) -> int:
    got = await pool.execute("DELETE FROM favorites WHERE account_id = $1 AND group_id = $2", account, group_id)
    return int(got.split()[-1])
