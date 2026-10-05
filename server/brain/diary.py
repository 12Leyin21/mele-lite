"""日记（10-01 Tilia点头，设计 specs/2026-10-01-diary-design.md；思路参考之前自用的 App，代码新写）。

两本：
- Ta 的（author=companion）：凌晨写前一天，一天一篇。正文 TA 能看；「还不想让 TA 看的那一段」锁着，TA 只看得见那里锁着一段，
  问 Ta 要钥匙（4 位数，跟抽屉同一套：第一次给时生成，连错 5 次锁 10 分钟，开过以后随时能看）。
  正文进记忆库（kind=diary，能被想起来）；锁着那段不进向量，Ta 自己用工具翻。
- TA 的（author=user）：能整篇锁起来，锁了 Ta 读不到；Ta 凌晨读没锁的，在页边留一句。永远不进记忆库。"""
from __future__ import annotations

import hmac
import random
from dataclasses import dataclass
from datetime import date, datetime
from uuid import UUID

import memory as M

from . import archive
from .drawer import FAILS_MAX, LOCK, new_code
from .persona import Persona

BODY_MAX, LOCKED_MAX, MARGIN_MAX = 6000, 2000, 300


@dataclass
class Entry:
    id: int
    account_id: UUID
    companion_id: UUID | None
    author: str
    day: date
    body: str
    locked: str
    private: bool
    margin: str
    margin_by: UUID | None
    margin_at: datetime | None
    code: str
    code_fails: int
    code_locked_until: datetime | None
    keyed_at: datetime | None
    unlocked_at: datetime | None
    told_unlocked: bool
    memory_id: int | None
    created_at: datetime
    updated_at: datetime


_COLS = ("id, account_id, companion_id, author, day, body, locked, private, margin, margin_by, margin_at, code, code_fails, "
         "code_locked_until, keyed_at, unlocked_at, told_unlocked, memory_id, created_at, updated_at")


def _row(r) -> Entry:
    return Entry(**dict(r))


def md(d: date) -> str:
    return f"{d.month}/{d.day}"


# ── TA 的 ──

async def write_mine(pool, account: UUID, *, day: date, body: str, private: bool, now: datetime) -> Entry:
    body = (body or "").strip()
    if not body:
        raise ValueError("日记是空的")
    r = await pool.fetchrow(f"""INSERT INTO diaries (account_id, author, day, body, private, created_at, updated_at)
                                VALUES ($1, 'user', $2, $3, $4, $5, $5) RETURNING {_COLS}""",
                            account, day, body[:BODY_MAX], bool(private), now)
    return _row(r)


async def edit_mine(pool, account: UUID, entry_id: int, *, body: str | None, private: bool | None, now: datetime,
                    day: date | None = None) -> Entry:
    if body is not None and not body.strip():
        raise ValueError("日记是空的")
    r = await pool.fetchrow(
        f"""UPDATE diaries SET body = COALESCE($3, body), private = COALESCE($4, private), day = COALESCE($5, day),
                               updated_at = $6
            WHERE id = $1 AND account_id = $2 AND author = 'user' RETURNING {_COLS}""",
        entry_id, account, body.strip()[:BODY_MAX] if body is not None else None, private, day, now)
    if r is None:
        raise LookupError("没有这篇")
    return _row(r)


async def delete_mine(pool, account: UUID, entry_id: int) -> bool:
    done = await pool.execute("DELETE FROM diaries WHERE id = $1 AND account_id = $2 AND author = 'user'",
                              entry_id, account)
    return done.endswith(" 1")


async def mine_for_companion(pool, account: UUID, day: date) -> list[Entry]:
    """Ta 读得到的 TA 那天的日记：没锁的，按写的先后。"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM diaries WHERE account_id = $1 AND author = 'user' AND day = $2 "
                            "AND NOT private ORDER BY created_at, id", account, day)
    return [_row(r) for r in rows]


async def set_margin(pool, companion: UUID, entry_id: int, text: str, now: datetime) -> bool:
    """Ta 在 TA 那篇页边留一句。只能写在同一个账号、没锁的那篇上。"""
    text = (text or "").strip()[:MARGIN_MAX]
    if not text:
        return False
    done = await pool.execute(
        """UPDATE diaries d SET margin = $3, margin_by = $2, margin_at = $4
           FROM companions c WHERE d.id = $1 AND c.id = $2 AND d.account_id = c.account_id
             AND d.author = 'user' AND NOT d.private""", entry_id, companion, text, now)
    return done.endswith(" 1")


# ── Ta 的 ──

_MEM_HEAD = {"zh": "〔我 {d} 的日记〕", "en": "〔My diary, {d}〕"}
_MEM_LOCKED = {"zh": "（那天我还锁了一段没给 TA 看。）", "en": "(That day I also locked a part away from them.)"}


def memory_text(day: date, body: str, has_locked: bool, lang: str) -> str:
    L = lang if lang in _MEM_HEAD else "en"
    return _MEM_HEAD[L].format(d=md(day)) + body.strip() + (_MEM_LOCKED[L] if has_locked else "")


async def save_companion_entry(pool, embedder, account: UUID, companion: UUID, *, day: date, body: str, locked: str,
                               now: datetime, lang: str = "zh") -> Entry:
    """存 Ta 那天的日记（同一天再存 = 改那篇），正文进记忆库（旧的那条换掉）。"""
    body, locked = (body or "").strip()[:BODY_MAX], (locked or "").strip()[:LOCKED_MAX]
    if not body:
        raise ValueError("日记是空的")
    old = await companion_entry(pool, companion, day)
    mem = await M.remember(pool, embedder, companion, memory_text(day, body, bool(locked), lang), kind="diary", now=now)
    if old is not None and old.memory_id:
        await M.delete(pool, companion, old.memory_id)
    r = await pool.fetchrow(
        f"""INSERT INTO diaries (account_id, companion_id, author, day, body, locked, memory_id, created_at, updated_at)
            VALUES ($1, $2, 'companion', $3, $4, $5, $6, $7, $7)
            ON CONFLICT (companion_id, day) WHERE author = 'companion'
            DO UPDATE SET body = EXCLUDED.body, locked = EXCLUDED.locked, memory_id = EXCLUDED.memory_id,
                          updated_at = EXCLUDED.updated_at
            RETURNING {_COLS}""", account, companion, day, body, locked, mem.memory.id, now)
    return _row(r)


async def companion_entry(pool, companion: UUID, day: date) -> Entry | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM diaries WHERE companion_id = $1 AND author = 'companion' AND day = $2",
                            companion, day)
    return _row(r) if r else None


async def delete_companion_entry(pool, companion: UUID, entry_id: int) -> bool:
    mid = await pool.fetchval("DELETE FROM diaries WHERE id = $1 AND companion_id = $2 AND author = 'companion' "
                              "RETURNING COALESCE(memory_id, 0)", entry_id, companion)
    if mid is None:
        return False
    if mid:
        await M.delete(pool, companion, mid)
    return True


async def give_key(pool, companion: UUID, day: date, rng: random.Random, now: datetime) -> str | None:
    """那天锁着那段的钥匙：第一次给时生成，之后再问还是同一串。那天没日记 / 没锁 → None。"""
    e = await companion_entry(pool, companion, day)
    if e is None or not e.locked:
        return None
    if e.code:
        return e.code
    code = new_code(rng)
    await pool.execute("UPDATE diaries SET code = $2, keyed_at = $3 WHERE id = $1", e.id, code, now)
    return code


async def unlock(pool, account: UUID, entry_id: int, code: str, now: datetime) -> tuple[str, object]:
    """TA 打开锁着那段。返回 ("ok", Entry) / ("wrong", 还剩几次) / ("locked", 还要等几秒) / ("sealed", None)
    / ("nothing", None) / ("missing", None)。sealed = Ta 还没给过钥匙；nothing = 那篇没锁东西。"""
    r = await pool.fetchrow(f"SELECT {_COLS} FROM diaries WHERE id = $1 AND account_id = $2 AND author = 'companion'",
                            entry_id, account)
    if r is None:
        return "missing", None
    e = _row(r)
    if not e.locked:
        return "nothing", None
    if e.unlocked_at is not None:
        return "ok", e
    if e.code_locked_until is not None and e.code_locked_until > now:
        return "locked", int((e.code_locked_until - now).total_seconds())
    if not e.code:
        return "sealed", None
    if not hmac.compare_digest((code or "").strip(), e.code):
        fails = e.code_fails + 1
        if fails >= FAILS_MAX:
            await pool.execute("UPDATE diaries SET code_fails = 0, code_locked_until = $2 WHERE id = $1", e.id, now + LOCK)
            return "locked", int(LOCK.total_seconds())
        await pool.execute("UPDATE diaries SET code_fails = $2 WHERE id = $1", e.id, fails)
        return "wrong", FAILS_MAX - fails
    r = await pool.fetchrow(f"UPDATE diaries SET unlocked_at = $2, code_fails = 0 WHERE id = $1 RETURNING {_COLS}",
                            e.id, now)
    return "ok", _row(r)


_UNLOCKED = {"zh": "〔TA 用钥匙打开了你 {d} 锁着的那段〕", "en": "〔They used the key and opened the part you locked on {d}〕"}


async def unlocked_lines(pool, companion: UUID, lang: str) -> list[str]:
    """TA 打开了哪天锁着的那段，下一轮告诉 Ta 一次。"""
    rows = await pool.fetch("""UPDATE diaries SET told_unlocked = TRUE WHERE companion_id = $1 AND author = 'companion'
                               AND unlocked_at IS NOT NULL AND NOT told_unlocked RETURNING day""", companion)
    L = _UNLOCKED[lang if lang in _UNLOCKED else "en"]
    return [L.format(d=md(r["day"])) for r in sorted(rows, key=lambda r: r["day"])]


# ── 给 app ──

async def list_for_account(pool, account: UUID, *, before: date | None, limit: int = 30) -> list[dict]:
    """两本一起，按天新的在前（同一天 Ta 的在前）。锁着那段只说「有」，打开过才给原文；钥匙永远不在这里。"""
    rows = await pool.fetch(
        f"""SELECT {_COLS} FROM diaries WHERE account_id = $1 AND ($2::date IS NULL OR day < $2)
            ORDER BY day DESC, author ASC, id DESC LIMIT $3""", account, before, max(1, min(limit, 100)))
    names: dict[UUID, str] = {}

    async def name(cid: UUID | None) -> str:
        if cid is None:
            return ""
        if cid not in names:
            names[cid] = Persona.from_dict(await archive.get_persona(pool, cid)).name
        return names[cid]

    out = []
    for e in map(_row, rows):
        item = {"id": e.id, "author": e.author, "day": e.day.isoformat(), "body": e.body,
                "written_at": e.created_at.isoformat(), "updated_at": e.updated_at.isoformat()}
        if e.author == "companion":
            item.update({"companion_id": str(e.companion_id), "from": await name(e.companion_id),
                         "has_locked": bool(e.locked)})
            if e.locked and e.unlocked_at is not None:
                item["locked"] = e.locked
        else:
            item.update({"private": e.private, "margin": e.margin, "margin_from": await name(e.margin_by)})
        out.append(item)
    return out
