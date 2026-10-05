"""抽屉（2026-09-28 Tilia定，设计 specs/2026-09-28-far-dates-and-drawer-design.md；思路参考之前自用的 App 09-07 的上锁抽屉，代码新写）。

一个账号一个抽屉，装着所有联系人写给 TA 的信。TA 只看得见信封：From 谁、哪天写的、哪天解锁、一把锁；
没开之前连标题都不给，正文和密码永远不走列表。
两种开法：到了解锁日（按写信联系人的时区）自己开；或者它给钥匙——服务器生成 4 位密码，它在聊天里告诉 TA。
密码只在服务器核对；连错 5 次这封锁 10 分钟。开过的以后随时能读。"""
from __future__ import annotations

import hmac
import random
from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from . import accounts, archive
from .persona import Persona
from .settings import Settings, parse_hm

__all__ = ["Letter", "replace", "openable", "new_code", "put", "mine", "give_key", "burn", "list_for_account",
           "open_letter", "queue_unlocks", "wake_line", "opened_lines"]

MAX_SEALED = 30                 # 没拆没烧的最多这么多，满了先烧
TITLE_MAX, CONTENT_MAX = 40, 4000
FAILS_MAX = 5
LOCK = timedelta(minutes=10)


@dataclass
class Letter:
    id: int
    account_id: UUID | None
    companion_id: UUID | None
    title: str
    content: str
    unlock_at: date | None
    code: str
    code_fails: int
    code_locked_until: datetime | None
    keyed_at: datetime | None
    opened_at: datetime | None
    notified_at: datetime | None
    told_opened: bool
    burned_at: datetime | None
    created_at: datetime


_COLS = ("id, account_id, companion_id, title, content, unlock_at, code, code_fails, code_locked_until, keyed_at, "
         "opened_at, notified_at, told_opened, burned_at, created_at")


def _row(r) -> Letter:
    return Letter(**dict(r))


def openable(letter: Letter, today: date) -> bool:
    """开过的，或者到了解锁日的，不用密码就能读。"""
    return letter.opened_at is not None or (letter.unlock_at is not None and letter.unlock_at <= today)


def new_code(rng: random.Random) -> str:
    return f"{rng.randrange(10000):04d}"


async def _today(pool, companion: UUID, now: datetime) -> date:
    tz = Settings.from_dict(await archive.get_settings(pool, companion)).tz
    return now.astimezone(ZoneInfo(tz)).date()


async def put(pool, account: UUID, companion: UUID, *, title: str, content: str, unlock_at: date | None,
              now: datetime) -> Letter:
    content, title = (content or "").strip(), (title or "").strip()[:TITLE_MAX]
    if not content:
        raise ValueError("信是空的")
    if not await pool.fetchval("SELECT EXISTS (SELECT 1 FROM companions WHERE id = $1 AND account_id = $2)",
                               companion, account):
        raise PermissionError("没有这个联系人")
    if unlock_at is not None and unlock_at < await _today(pool, companion, now):
        raise ValueError("解锁日已经过了")
    sealed = await pool.fetchval("SELECT count(*) FROM drawer_letters WHERE companion_id = $1 AND opened_at IS NULL "
                                 "AND burned_at IS NULL", companion)
    if sealed >= MAX_SEALED:
        raise ValueError(f"抽屉里已经有 {MAX_SEALED} 封还没拆的了，先烧几封再放")
    r = await pool.fetchrow(
        f"""INSERT INTO drawer_letters (account_id, companion_id, title, content, unlock_at, created_at)
            VALUES ($1, $2, $3, $4, $5, $6) RETURNING {_COLS}""", account, companion, title, content[:CONTENT_MAX],
        unlock_at, now)
    return _row(r)


async def mine(pool, companion: UUID) -> list[Letter]:
    """它自己翻：全文，新的在前。"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM drawer_letters WHERE companion_id = $1 AND burned_at IS NULL "
                            "ORDER BY created_at DESC, id DESC", companion)
    return [_row(r) for r in rows]


async def _mine_one(pool, companion: UUID, letter_id: int) -> Letter | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM drawer_letters WHERE id = $1 AND companion_id = $2 "
                            "AND burned_at IS NULL", letter_id, companion)
    return _row(r) if r else None


async def give_key(pool, companion: UUID, letter_id: int, rng: random.Random, now: datetime) -> str | None:
    """这封的密码：第一次给时生成，之后再问还是同一串。没有这封（或者烧了）返回 None。"""
    letter = await _mine_one(pool, companion, letter_id)
    if letter is None:
        return None
    if letter.code:
        return letter.code
    code = new_code(rng)
    await pool.execute("UPDATE drawer_letters SET code = $2, keyed_at = $3 WHERE id = $1", letter_id, code, now)
    return code


async def burn(pool, companion: UUID, letter_id: int, now: datetime) -> bool:
    done = await pool.execute("UPDATE drawer_letters SET burned_at = $3 WHERE id = $1 AND companion_id = $2 "
                              "AND burned_at IS NULL", letter_id, companion, now)
    return not done.endswith(" 0")


async def list_for_account(pool, account: UUID, now: datetime) -> list[dict]:
    """给 app 的信封：一行一封，新的在前。正文和密码永远不在这里；开过的才带标题。"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM drawer_letters WHERE account_id = $1 AND burned_at IS NULL "
                            "ORDER BY created_at DESC, id DESC", account)
    names: dict[UUID, str] = {}
    todays: dict[UUID, date] = {}
    out = []
    for letter in map(_row, rows):
        cid = letter.companion_id
        if cid not in names:
            names[cid] = Persona.from_dict(await archive.get_persona(pool, cid)).name
            todays[cid] = await _today(pool, cid, now)
        item = {"id": letter.id, "companion_id": str(cid), "from": names[cid], "written_at": letter.created_at.isoformat(),
                "unlock_at": letter.unlock_at.isoformat() if letter.unlock_at else None,
                "openable": openable(letter, todays[cid]), "opened": letter.opened_at is not None}
        if letter.opened_at is not None:
            item["title"] = letter.title
        out.append(item)
    return out


async def open_letter(pool, account: UUID, letter_id: int, code: str, now: datetime) -> tuple[str, object]:
    """TA 拆一封。返回 ("ok", Letter) / ("wrong", 还剩几次) / ("locked", 还要等几秒) / ("sealed", None) / ("missing", None)。
    sealed = 没到日子、它也还没给过钥匙。"""
    r = await pool.fetchrow(f"SELECT {_COLS} FROM drawer_letters WHERE id = $1 AND account_id = $2 "
                            "AND burned_at IS NULL", letter_id, account)
    if r is None:
        return "missing", None
    letter = _row(r)
    if not openable(letter, await _today(pool, letter.companion_id, now)):
        if letter.code_locked_until is not None and letter.code_locked_until > now:
            return "locked", int((letter.code_locked_until - now).total_seconds())
        if not letter.code:
            return "sealed", None
        if not hmac.compare_digest((code or "").strip(), letter.code):
            fails = letter.code_fails + 1
            if fails >= FAILS_MAX:
                await pool.execute("UPDATE drawer_letters SET code_fails = 0, code_locked_until = $2 WHERE id = $1",
                                   letter_id, now + LOCK)
                return "locked", int(LOCK.total_seconds())
            await pool.execute("UPDATE drawer_letters SET code_fails = $2 WHERE id = $1", letter_id, fails)
            return "wrong", FAILS_MAX - fails
    if letter.opened_at is None:
        await pool.execute("UPDATE drawer_letters SET opened_at = $2, code_fails = 0 WHERE id = $1", letter_id, now)
        letter = replace(letter, opened_at=now, code_fails=0)
    return "ok", letter


# ── 第 5 步：到日子推送、它知道什么 ──

_PUSH = {"zh": ("抽屉", "有一封今天解锁了", "有 {n} 封今天解锁了"),
         "en": ("Drawer", "A letter unlocked today", "{n} letters unlocked today")}


def push_title(lang: str) -> str:
    return _PUSH[lang if lang in _PUSH else "en"][0]


async def queue_unlocks(pool, now: datetime) -> int:
    """解锁日到了、写信那个联系人那边 TA 已经起床了、还没推过的：同一个账号合成一条推送。返回排了几条。"""
    rows = await pool.fetch(f"""SELECT {_COLS} FROM drawer_letters WHERE unlock_at IS NOT NULL AND notified_at IS NULL
                                AND opened_at IS NULL AND burned_at IS NULL AND unlock_at <= $1""",
                            now.date() + timedelta(days=1))
    due: dict[UUID, list[Letter]] = {}
    for letter in map(_row, rows):
        s = Settings.from_dict(await archive.get_settings(pool, letter.companion_id))
        local = now.astimezone(ZoneInfo(s.tz))
        if letter.unlock_at < local.date() or (letter.unlock_at == local.date() and local.time() >= parse_hm(s.sleep_to)):
            due.setdefault(letter.account_id, []).append(letter)
    for acc, letters in due.items():
        first = letters[0]
        lang = Settings.from_dict(await archive.get_settings(pool, first.companion_id)).lang
        _, one, many = _PUSH[lang if lang in _PUSH else "en"]
        conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND NOT incognito "
                                   "ORDER BY last_at DESC LIMIT 1", first.companion_id) \
            or await accounts.new_conversation(pool, acc, first.companion_id)
        await pool.execute("UPDATE drawer_letters SET notified_at = $2 WHERE id = ANY($1::bigint[])",
                           [x.id for x in letters], now)
        await pool.execute("INSERT INTO push_queue (account_id, companion_id, conversation_id, text, kind) "
                           "VALUES ($1, $2, $3, $4, 'drawer')", acc, first.companion_id, conv,
                           one if len(letters) == 1 else many.format(n=len(letters)))
    return len(due)


_WAKE_LINE = {"zh": "抽屉里有 {n} 封，{d} 封到了日子 TA 还没拆。", "en": "There are {n} letters in the drawer; {d} reached their day and they haven't opened yet."}


async def wake_line(pool, companion: UUID, now: datetime, lang: str) -> str:
    """〔醒来〕末尾那行：有到了日子还没拆的才写。"""
    letters = await mine(pool, companion)
    today = await _today(pool, companion, now)
    d = sum(1 for x in letters if x.opened_at is None and openable(x, today))
    return _WAKE_LINE[lang if lang in _WAKE_LINE else "en"].format(n=len(letters), d=d) if d else ""


_OPENED = {"zh": "〔TA 拆了你 {d} 写的那封{t}〕", "en": "〔They opened the letter you wrote on {d}{t}〕"}


async def opened_lines(pool, companion: UUID, tz: str, lang: str) -> list[str]:
    """TA 拆了哪封，下一轮告诉它一次。"""
    rows = await pool.fetch("""UPDATE drawer_letters SET told_opened = TRUE WHERE companion_id = $1
                               AND opened_at IS NOT NULL AND NOT told_opened AND burned_at IS NULL
                               RETURNING title, created_at""", companion)
    L = _OPENED[lang if lang in _OPENED else "en"]
    out = []
    for r in sorted(rows, key=lambda r: r["created_at"]):
        day = r["created_at"].astimezone(ZoneInfo(tz))
        d = f"{day.month}/{day.day}"
        t = (f"《{r['title']}》" if lang == "zh" else f' "{r["title"]}"') if r["title"] else ""
        out.append(L.format(d=d, t=t))
    return out
