"""Mele Host 配对码（10-04）：单人服务器的主人怎么进来。

服务器第一次起来出一张配对码（打在日志 / 安装脚本里，配二维码），App 扫了换一张登录凭证。
码只存哈希、用一次就作废；重置 = 作废所有没用的、出一张新的。主人只有一个：再配对还是同一个账号。"""
from __future__ import annotations

import secrets
from datetime import datetime
from uuid import UUID

from . import auth

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"     # 不要 0 / O / 1 / I，念给人听不会看错


class PairError(Exception):
    pass


def normalize(code: str) -> str:
    return "".join(ch for ch in (code or "").upper() if ch.isalnum())


async def new_code(pool, *, secret: str, now: datetime) -> str:
    raw = "".join(secrets.choice(ALPHABET) for _ in range(8))
    async with pool.acquire() as conn, conn.transaction():
        await conn.execute("DELETE FROM host_pairing WHERE used_at IS NULL")
        await conn.execute("INSERT INTO host_pairing (code_hash, created_at) VALUES ($1, $2)",
                           auth._hash(secret, "pair", raw), now)
    return f"{raw[:4]}-{raw[4:]}"


async def has_code(pool) -> bool:
    return bool(await pool.fetchval("SELECT 1 FROM host_pairing WHERE used_at IS NULL LIMIT 1"))


async def owner(pool) -> UUID | None:
    return await pool.fetchval("SELECT id FROM accounts ORDER BY created_at, id LIMIT 1")


async def pair(pool, code: str, *, secret: str, now: datetime, tz: str = "UTC") -> UUID:
    used = await pool.fetchval(
        "UPDATE host_pairing SET used_at = $2 WHERE code_hash = $1 AND used_at IS NULL RETURNING code_hash",
        auth._hash(secret, "pair", normalize(code)), now)
    if not used:
        raise PairError("配对码不对，或者已经用过了")
    acc = await owner(pool)
    if acc is None:
        acc = await auth.new_account(pool, tz=tz)
        await pool.execute("UPDATE accounts SET plan = 'byok' WHERE id = $1", acc)
    return acc
