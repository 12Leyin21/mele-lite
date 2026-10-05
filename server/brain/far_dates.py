"""记着的远事（2026-09-28 Tilia定，设计 specs/2026-09-28-far-dates-and-drawer-design.md）。

它帮 TA 记着有日子、还远、要一路惦记着的事（坐飞机、考试、面试）。TA 看得见、能改能删（看不见的东西留给抽屉）。
- 平时：两周以内的，每轮易变区一行「还有 3 天：12/1 坐飞机」。
- 醒来三次：前一晚（睡前两小时）、当天（有几点提前三小时，没有就起床后一小时）、第二天下午三点问怎么样。
  这三次存成巡逻的一次性钟（kind='date'），一定要开口（wake_text.MUST_SPEAK）。
- 了结：问过了它标了结 → 存一条普通记忆、从清单拿掉；第二天过后两天还没标的自动了结。

时间都按这个联系人的时区、作息算，墙上的钟说了算（夏令时那天照旧）。"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

import memory as M
from patrol import store as clock_store
from patrol.clocks import _mins, _utc, _wall

from . import archive
from .settings import Settings, parse_hm

NEAR_DAYS = 14          # 易变区只提两周以内的
MAX_LINES = 5
EARLY_BED = 5 * 60      # 睡觉时间在 00:00~05:00 的，算前一天夜里
EVE_BEFORE_BED = 120    # 前一晚：睡前两小时
DAY_BEFORE = 180        # 当天有几点：提前三小时
AFTER_WAKE_MIN = 30     # 当天最早：起床后半小时
AFTER_WAKE_NO_TIME = 60 # 当天没几点：起床后一小时
AFTER_AT = 15 * 60      # 第二天：下午三点
AUTO_RESOLVE_DAYS = 3   # 日子过后第三天还没了结的，自动了结（第二天那次问过、再等两天）
TITLE_MAX, NOTE_MAX = 60, 200


@dataclass
class FarDate:
    id: int
    account_id: UUID | None
    companion_id: UUID | None
    day: date
    at_time: str            # 'HH:MM' 或空
    title: str
    note: str
    created_at: datetime | None
    resolved_at: datetime | None
    result: str


def wake_times(day: date, at_time: str, tz: str, sleep_from: str, sleep_to: str,
               now: datetime) -> list[tuple[str, datetime]]:
    """[(phase, UTC 时间)]，phase = eve / day / after，已经过了的不要。"""
    bed = _mins(sleep_from)
    bed = bed + 1440 if bed < EARLY_BED else bed                    # 一点睡 = 前一天的第 25 个钟头
    up = _mins(sleep_to)
    if at_time:
        at = _mins(at_time)
        # 提前三小时；太早就挪到起床后半小时；可挪过去又过了点（早班机），就改成提前半小时
        on_day = max(0, min(max(at - DAY_BEFORE, up + AFTER_WAKE_MIN), at - 30))
    else:
        on_day = up + AFTER_WAKE_NO_TIME
    prev, nxt = date.fromordinal(day.toordinal() - 1), date.fromordinal(day.toordinal() + 1)
    out = [("eve", _wall(prev, bed - EVE_BEFORE_BED, tz)), ("day", _wall(day, on_day, tz)),
           ("after", _wall(nxt, AFTER_AT, tz))]
    return [(p, t) for p, t in out if t > _utc(now)]


_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
_LINE = {
    "zh": {"yesterday": "昨天：{t}（还没问怎么样）", "today": "今天：{t}{at}", "tomorrow": "明天：{t}{at}",
           "later": "还有 {n} 天：{d} {t}{at}", "at": "（{a}）"},
    "en": {"yesterday": "Yesterday: {t} (haven't asked how it went)", "today": "Today: {t}{at}",
           "tomorrow": "Tomorrow: {t}{at}", "later": "In {n} days: {d} {t}{at}", "at": " ({a})"},
}


def _day_label(d: date, lang: str) -> str:
    return f"{d.month}/{d.day}" if lang == "zh" else f"{_MONTHS[d.month - 1]} {d.day}"


def lines(dates: list[FarDate], today: date, lang: str) -> list[str]:
    """易变区那几行：昨天（还没了结的）到两周以内，按日子排，最多 5 行。"""
    L = _LINE[lang if lang in _LINE else "en"]
    out = []
    for f in sorted(dates, key=lambda f: (f.day, f.at_time or "", f.id)):
        n = (f.day - today).days
        if not -1 <= n <= NEAR_DAYS or f.resolved_at is not None:
            continue
        at = L["at"].format(a=f.at_time) if f.at_time else ""
        key = {-1: "yesterday", 0: "today", 1: "tomorrow"}.get(n, "later")
        out.append(L[key].format(t=f.title, at=at, n=n, d=_day_label(f.day, lang)))
    return out[:MAX_LINES]


# ── 读写（第 2 步）──

_COLS = "id, account_id, companion_id, day, at_time, title, note, created_at, resolved_at, result"


def _row(r) -> FarDate:
    return FarDate(**dict(r))


def _today(now: datetime, tz: str) -> date:
    return now.astimezone(ZoneInfo(tz)).date()


def _clean(day: date, at_time: str, title: str, note: str, today: date) -> tuple[str, str, str]:
    if day < today:
        raise ValueError(f"这个日子已经过了（今天是 {today.isoformat()}）")
    at_time = (at_time or "").strip()
    if at_time:
        at_time = f"{parse_hm(at_time):%H:%M}"
    title, note = (title or "").strip(), (note or "").strip()
    if not title or len(title) > TITLE_MAX:
        raise ValueError(f"要写是什么事，{TITLE_MAX} 字以内")
    return at_time, title, note[:NOTE_MAX]


async def _schedule(pool, f: FarDate, s: Settings, now: datetime) -> None:
    for phase, at in wake_times(f.day, f.at_time, s.tz, s.sleep_from, s.sleep_to, now):
        await clock_store.add_clock(pool, f.account_id, f.companion_id, kind="date", shape="once",
                                    spec={"at": at.isoformat(), "date_id": f.id, "phase": phase}, note="", next_at=at)


async def _unschedule(pool, date_id: int) -> None:
    await pool.execute("DELETE FROM clocks WHERE kind = 'date' AND (spec->>'date_id')::bigint = $1", date_id)


async def add(pool, account: UUID, companion: UUID, s: Settings, *, day: date, title: str, at_time: str = "",
              note: str = "", now: datetime) -> FarDate:
    at_time, title, note = _clean(day, at_time, title, note, _today(now, s.tz))
    r = await pool.fetchrow(
        f"""INSERT INTO far_dates (account_id, companion_id, day, at_time, title, note, created_at)
            SELECT $1, $2, $3, $4, $5, $6, $7 WHERE EXISTS (SELECT 1 FROM companions WHERE id = $2 AND account_id = $1)
            RETURNING {_COLS}""", account, companion, day, at_time, title, note, now)
    if r is None:
        raise PermissionError("没有这个联系人")
    f = _row(r)
    await _schedule(pool, f, s, now)
    return f


async def get(pool, account: UUID, date_id: int) -> FarDate | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM far_dates WHERE id = $1 AND account_id = $2", date_id, account)
    return _row(r) if r else None


async def list_open(pool, account: UUID, companion: UUID) -> list[FarDate]:
    rows = await pool.fetch(f"""SELECT {_COLS} FROM far_dates WHERE account_id = $1 AND companion_id = $2
                                AND resolved_at IS NULL ORDER BY day, at_time, id""", account, companion)
    return [_row(r) for r in rows]


_KEEP = object()


async def update(pool, account: UUID, date_id: int, s: Settings, *, day: date | None = None, at_time=_KEEP,
                 title: str | None = None, note: str | None = None, now: datetime) -> FarDate | None:
    """只改带了的；改了日子或几点就把三次醒来重排。了结过的、别人的返回 None。"""
    f = await get(pool, account, date_id)
    if f is None or f.resolved_at is not None:
        return None
    new_day = f.day if day is None else day
    new_at = f.at_time if at_time is _KEEP else (at_time or "")
    at_clean, title_clean, note_clean = _clean(new_day, new_at, f.title if title is None else title,
                                               f.note if note is None else note, _today(now, s.tz))
    r = await pool.fetchrow(f"""UPDATE far_dates SET day = $2, at_time = $3, title = $4, note = $5 WHERE id = $1
                                RETURNING {_COLS}""", date_id, new_day, at_clean, title_clean, note_clean)
    g = _row(r)
    if (g.day, g.at_time) != (f.day, f.at_time):
        await _unschedule(pool, date_id)
        await _schedule(pool, g, s, now)
    return g


async def delete(pool, account: UUID, date_id: int) -> bool:
    """TA 在 app 里删：拿掉、钟一起删，不存记忆。"""
    done = await pool.execute("DELETE FROM far_dates WHERE id = $1 AND account_id = $2", date_id, account)
    if done.endswith(" 0"):
        return False
    await _unschedule(pool, date_id)
    return True


async def resolve(pool, embedder, account: UUID, date_id: int, result: str, *, now: datetime) -> FarDate | None:
    """了结：存一条普通记忆（「2026-12-01 坐飞机：顺利」），剩下的钟删掉，从清单拿掉。"""
    result = (result or "").strip()[:NOTE_MAX]
    r = await pool.fetchrow(f"""UPDATE far_dates SET resolved_at = $3, result = $4
                                WHERE id = $1 AND account_id = $2 AND resolved_at IS NULL RETURNING {_COLS}""",
                            date_id, account, now, result)
    if r is None:
        return None
    f = _row(r)
    await _unschedule(pool, date_id)
    content = f"{f.day.isoformat()} {f.title}" + (f"：{result}" if result else "")
    await M.remember(pool, embedder, f.companion_id, content, resolved=True, now=now)
    return f


async def auto_resolve(pool, embedder, now: datetime) -> int:
    """日子过后第三天（按各自时区）还没了结的，自动了结，只存事和日子。返回了结了几件。"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM far_dates WHERE resolved_at IS NULL AND day <= $1",
                            (now.astimezone(ZoneInfo("UTC")).date() - timedelta(days=AUTO_RESOLVE_DAYS - 1)))
    n = 0
    for f in map(_row, rows):
        tz = Settings.from_dict(await archive.get_settings(pool, f.companion_id)).tz
        if (_today(now, tz) - f.day).days >= AUTO_RESOLVE_DAYS and await resolve(pool, embedder, f.account_id, f.id, "",
                                                                                 now=now):
            n += 1
    return n


async def open_lines(pool, companion: UUID, now: datetime, tz: str, lang: str) -> list[str]:
    """易变区用：这个联系人没了结的远事那几行。"""
    rows = await pool.fetch(f"""SELECT {_COLS} FROM far_dates WHERE companion_id = $1 AND resolved_at IS NULL
                                AND day <= $2""", companion, _today(now, tz) + timedelta(days=NEAR_DAYS))
    return lines([_row(r) for r in rows], _today(now, tz), lang)


_WAKE = {
    "zh": {"eve": "明天是 TA 的一件事：{t}{at}。", "day": "今天是 TA 的一件事：{t}{at}。",
           "after": "昨天是 TA 的一件事：{t}。我想知道怎么样了。问过了就用 remember_date 标了结，把结果写上。",
           "at": "（{a}）", "note": "备注：{n}"},
    "en": {"eve": "Tomorrow they have something: {t}{at}.", "day": "Today they have something: {t}{at}.",
           "after": "Yesterday they had something: {t}. I want to know how it went. Once I've asked, "
                    "I close it with remember_date and write down how it went.",
           "at": " ({a})", "note": "Note: {n}"},
}


async def wake_note(pool, spec: dict, lang: str) -> str | None:
    """date 钟响的时候，〔醒来〕里那句「我记着的事」。远事删了 / 了结了返回 None（钟作废）。"""
    r = await pool.fetchrow(f"SELECT {_COLS} FROM far_dates WHERE id = $1 AND resolved_at IS NULL",
                            int(spec.get("date_id") or 0))
    if r is None:
        return None
    f, L = _row(r), _WAKE[lang if lang in _WAKE else "en"]
    line = L[spec.get("phase", "day")].format(t=f.title, at=L["at"].format(a=f.at_time) if f.at_time else "")
    return f"{line} {L['note'].format(n=f.note)}" if f.note else line
