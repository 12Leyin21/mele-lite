"""账号、联系人、窗口的增删查（2026-09-27）。每个查询都带着上一层的 id，拿别人家的 id 查不到东西。"""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID

import memory as M

from . import album, archive, attachments, books, favorites, lore, tarot, wallet
from .scope import Scope
from .settings import Settings


@dataclass
class Conversation:
    id: UUID
    companion_id: UUID
    incognito: bool
    created_at: datetime
    last_at: datetime
    title: str = ""


async def create_account(pool, account_id: UUID | None = None) -> UUID:
    aid = account_id or uuid.uuid4()
    await pool.execute("INSERT INTO accounts (id) VALUES ($1) ON CONFLICT DO NOTHING", aid)
    return aid


async def create_companion(pool, account_id: UUID, companion_id: UUID | None = None) -> UUID:
    cid = companion_id or uuid.uuid4()
    await pool.execute(
        """INSERT INTO companions (id, account_id, sort)
           VALUES ($1, $2, (SELECT COALESCE(MAX(sort) + 1, 0) FROM companions WHERE account_id = $2))
           ON CONFLICT DO NOTHING""", cid, account_id)
    return cid


async def list_companions(pool, account_id: UUID) -> list[UUID]:
    rows = await pool.fetch("SELECT id FROM companions WHERE account_id = $1 ORDER BY sort, created_at", account_id)
    return [r["id"] for r in rows]


async def new_conversation(pool, account_id: UUID, companion_id: UUID, *, incognito: bool = False,
                           conversation_id: UUID | None = None) -> UUID:
    """开新窗口：不带旧账本、旧聊天，记忆照旧在联系人名下（所以还记得 TA）。"""
    owner = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", companion_id)
    if owner != account_id:
        raise PermissionError("这个联系人不在这个账号下")
    vid = conversation_id or uuid.uuid4()
    await pool.execute(
        "INSERT INTO conversations (id, account_id, companion_id, incognito) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
        vid, account_id, companion_id, incognito)
    return vid


async def list_conversations(pool, account_id: UUID, companion_id: UUID) -> list[Conversation]:
    rows = await pool.fetch(
        """SELECT id, companion_id, incognito, created_at, last_at, title FROM conversations
           WHERE account_id = $1 AND companion_id = $2 AND NOT incognito ORDER BY last_at DESC""",
        account_id, companion_id)
    return [Conversation(**dict(r)) for r in rows]


async def scope_for(pool, account_id: UUID, conversation_id: UUID) -> Scope:
    """凭账号 + 窗口 id 拿到完整的 Scope；窗口不是这个账号的就拒绝。"""
    r = await pool.fetchrow("SELECT companion_id, incognito FROM conversations WHERE id = $1 AND account_id = $2",
                            conversation_id, account_id)
    if r is None:
        raise PermissionError("找不到这个窗口")
    return Scope(account_id, r["companion_id"], conversation_id, incognito=r["incognito"])


async def touch_conversation(pool, conversation_id: UUID, now: datetime) -> None:
    await pool.execute("UPDATE conversations SET last_at = $2 WHERE id = $1", conversation_id, now)


# ── 删联系人、删号、导出、我的设定（2026-09-27，第 4 步正式接口） ──

async def _erase_companion(pool, companion_id: UUID) -> None:
    """一个联系人名下的一切：记忆、关于 TA、便利贴、设置、人设，它所有窗口的聊天、账本、状态、日志、倒回记账。"""
    convs = [r["id"] for r in await pool.fetch("SELECT id FROM conversations WHERE companion_id = $1", companion_id)]
    for conv in convs:
        await attachments.wipe(pool, "conversation_id", conv)
        await archive.wipe(pool, conv)
        await pool.execute("DELETE FROM memory_edits WHERE conversation_id = $1", conv)
    await M.wipe(pool, companion_id)
    await album.wipe(pool, companion_id)
    await archive.wipe(pool, companion_id)
    await pool.execute("DELETE FROM memory_edits WHERE owner = $1", companion_id)
    await pool.execute("DELETE FROM companions WHERE id = $1", companion_id)     # 窗口跟着连带删


async def delete_companion(pool, account_id: UUID, companion_id: UUID) -> None:
    ids = await list_companions(pool, account_id)
    if companion_id not in ids:
        raise PermissionError("没有这个联系人")
    if len(ids) == 1:
        raise ValueError("最后一个联系人不能删")
    await _erase_companion(pool, companion_id)


async def delete_account(pool, account_id: UUID) -> None:
    """删号：这个账号名下的都真删。只留「这台手机用过试用」的哈希（trial_devices），不然删号重来就能再领一次。"""
    for cid in await list_companions(pool, account_id):
        await _erase_companion(pool, cid)
    await attachments.wipe(pool, "account_id", account_id)
    for b in await pool.fetch("SELECT id FROM books WHERE account_id = $1", account_id):   # 书的文件（10-02）
        await books.delete(pool, account_id, b["id"])
    await M.wipe(pool, account_id)                     # 人物卡
    await archive.wipe(pool, account_id)               # 用量
    await pool.execute("DELETE FROM memory_edits WHERE owner = $1", account_id)
    email = await pool.fetchval("SELECT email FROM accounts WHERE id = $1", account_id)
    if email:
        await pool.execute("DELETE FROM login_codes WHERE email = $1", email)
    await pool.execute("DELETE FROM accounts WHERE id = $1", account_id)       # 登录凭证、钥匙串连带删


async def _music_export(pool, account_id: UUID) -> dict:
    from music import store as music_store             # 音乐在 brain 外面，同饮食
    return await music_store.export(pool, account_id)


async def _food_export(pool, account_id: UUID) -> dict:
    from food import store as food_store               # 饮食在 brain 外面，用到时才引，免得绕圈
    return await food_store.export(pool, account_id)


async def export_account(pool, account_id: UUID) -> dict:
    """导出：一个 JSON 装下全部。钥匙只给是哪家、哪个模型、后 4 位，不给原文。"""
    acc = await pool.fetchrow("SELECT email, plan, created_at, profile FROM accounts WHERE id = $1",
                              account_id)
    keys = await pool.fetch("SELECT id, provider, chat_model, base_url, last4 FROM keyring WHERE account_id = $1 "
                            "ORDER BY created_at", account_id)
    comps = []
    for cid in await list_companions(pool, account_id):
        mem = await M.export(pool, cid)
        convs = []
        for c in await pool.fetch("SELECT id, incognito, created_at, last_at FROM conversations "
                                  "WHERE companion_id = $1 AND NOT incognito ORDER BY created_at", cid):
            data = await archive.export(pool, c["id"])
            convs.append({"id": str(c["id"]), "created_at": c["created_at"].isoformat(),
                          "last_at": c["last_at"].isoformat(), "messages": data["messages"], "ledger": data["ledger"]})
        dates = await pool.fetch("SELECT day, at_time, title, note, created_at, resolved_at, result FROM far_dates "
                                 "WHERE companion_id = $1 ORDER BY day, id", cid)
        comps.append({"id": str(cid), "memories": mem["memories"], "sticky": mem["sticky"],
                      "far_dates": [{"day": d["day"].isoformat(), "time": d["at_time"], "title": d["title"],
                                     "note": d["note"], "created_at": d["created_at"].isoformat(),
                                     "resolved_at": d["resolved_at"].isoformat() if d["resolved_at"] else None,
                                     "result": d["result"]} for d in dates],
                      "settings": await archive.get_settings(pool, cid),
                      "personas": await archive.persona_history(pool, cid, limit=1000), "conversations": convs})
    people = await M.export(pool, account_id)
    usage = await archive.export(pool, account_id)
    return {
        "account": {"email": acc["email"], "plan": acc["plan"],
                    "created_at": acc["created_at"].isoformat(), "profile": _json(acc["profile"])},
        "keys": [{"id": str(k["id"]), "provider": k["provider"], "chat_model": k["chat_model"],
                  "base_url": k["base_url"], "last4": k["last4"]} for k in keys],
        "people": people["memories"],
        "usage": usage["usage"],
        "food": await _food_export(pool, account_id),         # 饮食（09-29）
        "music": await _music_export(pool, account_id),       # 音乐（09-30，不带用户凭证）
        "lore": await lore.export(pool, account_id),          # 世界书（09-30）
        "favorites": await favorites.list_all(pool, account_id),   # 收藏夹（10-02）
        "album": await album.export(pool, account_id),             # 相册的字（10-02，照片本身不进 JSON）
        "books": await books.export(pool, account_id),             # 书架：书名、读到哪、页边（10-02，正文不进 JSON）
        "wallet": await wallet.export(pool, account_id),           # 钱包记账（10-02）
        "tarot": await tarot.export(pool, account_id),             # 塔罗档案（10-03）
        "companions": comps,
        # 抽屉：拆过的带全文；没拆的只带日子——导出也不能拿来偷看（09-28）
        "drawer": [{"companion_id": str(r["companion_id"]), "written_at": r["created_at"].isoformat(),
                    "unlock_at": r["unlock_at"].isoformat() if r["unlock_at"] else None,
                    **({"title": r["title"], "content": r["content"], "opened_at": r["opened_at"].isoformat()}
                       if r["opened_at"] else {})}
                   for r in await pool.fetch("SELECT companion_id, created_at, unlock_at, title, content, opened_at "
                                             "FROM drawer_letters WHERE account_id = $1 AND burned_at IS NULL "
                                             "ORDER BY created_at", account_id)],
    }


def _json(v) -> dict:
    return json.loads(v) if isinstance(v, str) else dict(v or {})


PROFILE_KEYS = ("name", "pronoun", "looks")


async def get_profile(pool, account_id: UUID) -> dict:
    p = _json(await pool.fetchval("SELECT profile FROM accounts WHERE id = $1", account_id))
    return {"name": p.get("name", ""), "pronoun": p.get("pronoun", "they"), "looks": p.get("looks", "")}


async def save_profile(pool, account_id: UUID, profile: dict) -> dict:
    """我的设定（v1）：账号级一份，名字和指代顺手写进每个联系人的设置（账本、思考风格要用）。
    外貌先只存着，等做 app 的「我的设定」页再决定怎么给它看。"""
    p = {k: profile[k] for k in PROFILE_KEYS if k in profile}
    merged = {**await get_profile(pool, account_id), **p}
    for cid in await list_companions(pool, account_id):
        s = await archive.get_settings(pool, cid)
        s.update(user_name=merged["name"], user_pronoun=merged["pronoun"])
        await archive.save_settings(pool, cid, Settings.from_dict(s).to_dict())    # 名字太长、指代不对在这里报错
    await pool.execute("UPDATE accounts SET profile = $2::jsonb WHERE id = $1", account_id, json.dumps(merged))
    return merged
