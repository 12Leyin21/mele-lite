"""Mele Host 搬家（10-04 第三步）：Lite 手机里的东西一次性整包搬上 Host。

第一版搬核心：我的设定、模型钥匙（原文进来，用 Host 的主密钥加密存）、联系人（人设、设置、头像、用哪把钥匙）、
每个窗口的聊天（按原来的时间）。房间（日记、相册、书架……）后面一样样加，包里多出来的键先不认。
- 联系人和窗口用手机里的 UUID：同一个包再搬一次不会重复（已经有的跳过）。
- Host 配对时送的那个空 Lumi（一句都没聊过）在搬进来的联系人面前让位。
- 设置过一遍 Settings（不认识的键丢掉、不合法的报错），跟 Host 自己存的一样干净。"""
from __future__ import annotations

import base64
import binascii
from datetime import datetime
from pathlib import Path
from uuid import UUID

from . import accounts, archive, auth, avatars
from .settings import Settings

VERSION = 1


class ImportError_(Exception):
    pass


def _when(v, fallback: datetime) -> datetime:
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return fallback


async def _empty_defaults(pool, acc: UUID) -> list[UUID]:
    """一句都没聊过的联系人（配对时送的 Lumi）"""
    rows = await pool.fetch(
        """SELECT c.id FROM companions c WHERE c.account_id = $1 AND NOT EXISTS (
             SELECT 1 FROM conversations v JOIN chat_messages m ON m.user_id = v.id WHERE v.companion_id = c.id)""", acc)
    return [r["id"] for r in rows]


async def run(pool, box: auth.KeyBox, acc: UUID, bundle: dict, *, files_dir: Path, now: datetime) -> dict:
    if bundle.get("version") != VERSION:
        raise ImportError_(f"搬家包的版本对不上（{bundle.get('version')}），把 App 和 Host 都更新到最新")
    counts = {"companions": 0, "conversations": 0, "messages": 0, "keys": 0}

    key_ids: dict[str, UUID] = {}
    for k in bundle.get("keys") or []:
        try:
            key_ids[str(k.get("local_id"))] = await auth.add_key(
                pool, box, acc, provider=str(k.get("provider") or ""), api_key=str(k.get("api_key") or ""),
                chat_model=str(k.get("chat_model") or ""), base_url=k.get("base_url") or None)
            counts["keys"] += 1
        except auth.AuthError:
            continue                                   # 手机里一把坏 key 不挡整个搬家

    comps = bundle.get("companions") or []
    existing = set(await accounts.list_companions(pool, acc))
    empty = [c for c in await _empty_defaults(pool, acc)] if comps else []

    for c in comps:
        try:
            cid = UUID(str(c.get("id")))
        except ValueError:
            continue
        if cid in existing:
            continue
        await accounts.create_companion(pool, acc, cid)
        counts["companions"] += 1
        await archive.save_persona(pool, cid, dict(c.get("persona") or {}), now=now)
        try:
            settings = Settings.from_dict(c.get("settings") or {}).to_dict()
        except (TypeError, ValueError):
            settings = Settings().to_dict()
        await archive.save_settings(pool, cid, settings, now=now)
        if (kid := key_ids.get(str(c.get("key_local_id")))) is not None:
            await auth.use_key(pool, acc, cid, kid)
        if c.get("avatar_b64"):
            try:
                avatars.save(files_dir, cid, base64.b64decode(c["avatar_b64"]))
                await pool.execute("UPDATE companions SET avatar_ver = avatar_ver + 1 WHERE id = $1", cid)
            except (avatars.AvatarError, binascii.Error, ValueError):
                pass
        for v in c.get("conversations") or []:
            try:
                vid = UUID(str(v.get("id")))
            except ValueError:
                continue
            await accounts.new_conversation(pool, acc, cid, conversation_id=vid)
            counts["conversations"] += 1
            last = now
            for m in v.get("messages") or []:
                text = str(m.get("text") or "")
                role = m.get("role")
                if role not in ("user", "assistant") or not text.strip():
                    continue
                last = _when(m.get("at"), now)
                await archive.add_message(pool, vid, role, text, thinking=str(m.get("thinking") or ""),
                                          thinking_ms=m.get("thinking_ms") if isinstance(m.get("thinking_ms"), int) else None,
                                          now=last)
                counts["messages"] += 1
            await pool.execute("UPDATE conversations SET last_at = $2 WHERE id = $1", vid, last)

    if counts["companions"]:                           # 搬进来了才让位（不然最后一个联系人不能删）
        for cid in empty:
            await accounts.delete_companion(pool, acc, cid)

    if isinstance(bundle.get("profile"), dict):
        try:
            await accounts.save_profile(pool, acc, bundle["profile"])
        except (TypeError, ValueError):
            pass
    return counts
