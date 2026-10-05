"""日记的钟（日记第 3 步，10-01 Tilia：Ta 凌晨确认 TA 睡了才写，不然会聊到一半跑去写日记）。

每个账号一个，挂在主联系人上（照早上那个钟）。第一次看 = 当地 00:30；TA 的入睡时间在午夜后的话 = 入睡时间 + 45 分钟（取晚的）。
写哪天 = 第一次看那天的前一天（挂钟时就定好，存在 spec.day）。
TA 最后一句（这个账号任何窗口）离现在 ≥ 45 分钟、主联系人的窗口没在跑 → 写；不然 20 分钟后再看。
到 TA 的起床时间还没等到 → 这天不写。写完 / 不写 / 没材料都挂明晚。不进醒来账、不占每天的份、不推送。"""
from __future__ import annotations

import logging
from datetime import date, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from brain import accounts, archive
from brain.diary_write import write_day
from brain.settings import Settings, parse_hm

log = logging.getLogger(__name__)

EARLIEST = time(0, 30)
AFTER_SLEEP = timedelta(minutes=45)
QUIET = timedelta(minutes=45)
RETRY = timedelta(minutes=20)
MAX_TRIES = 3                  # 交卷拆不出 / 模型出错，一晚最多试三次


def first_check(morning: date, s: Settings) -> datetime:
    """morning 那天凌晨第一次看的时刻（TA 的时区）。"""
    tz = ZoneInfo(s.tz)
    at = datetime.combine(morning, EARLIEST, tzinfo=tz)
    sf, st = parse_hm(s.sleep_from), parse_hm(s.sleep_to)
    if sf < st:                                            # 午夜后才睡（含 00:00）：入睡时间 + 45 分钟
        at = max(at, datetime.combine(morning, sf, tzinfo=tz) + AFTER_SLEEP)
    return at


def deadline(morning: date, s: Settings, at: datetime) -> datetime:
    d = datetime.combine(morning, parse_hm(s.sleep_to), tzinfo=ZoneInfo(s.tz))
    return d if d > at else at + timedelta(hours=6)       # 作息填得怪（起床比第一次看还早）：给六个小时


def next_slot(now: datetime, s: Settings) -> tuple[datetime, date, datetime]:
    """下一次第一次看：(什么时候, 写哪天, 最晚到什么时候)。今天的过了就明天。"""
    local = now.astimezone(ZoneInfo(s.tz)).date()
    for morning in (local, local + timedelta(days=1)):
        at = first_check(morning, s)
        if at > now:
            return at, morning - timedelta(days=1), deadline(morning, s, at)
    raise AssertionError("unreachable")


async def ensure_clock(pool, account: UUID, now: datetime) -> None:
    from patrol import store as clock_store
    comps = await accounts.list_companions(pool, account)
    await pool.execute("DELETE FROM clocks WHERE account_id = $1 AND kind = 'diary'", account)
    if not comps:
        return
    s = Settings.from_dict(await archive.get_settings(pool, comps[0]))
    at, day, until = next_slot(now, s)
    await clock_store.add_clock(pool, account, comps[0], kind="diary", shape="once",
                                spec={"at": at.isoformat(), "day": day.isoformat(), "until": until.isoformat()},
                                note="", next_at=at)


async def ensure_all(pool, now: datetime) -> int:
    rows = await pool.fetch("""SELECT DISTINCT c.account_id FROM companions c
                               WHERE NOT EXISTS (SELECT 1 FROM clocks k WHERE k.account_id = c.account_id AND k.kind = 'diary')""")
    for r in rows:
        await ensure_clock(pool, r["account_id"], now)
    return len(rows)


async def _free_peak(deps, account: UUID, companion: UUID, now: datetime) -> datetime | None:
    """走我们试用钥匙（DeepSeek）的、现在又是高峰：返回高峰结束的时刻。美国作息的人半夜正好撞上 UTC 早上的高峰。"""
    from brain.auth import TrialOver
    from brain.scope import Scope
    from brain.turn import resolve_route
    from llm.catalog import deepseek_peak_until
    try:
        route = await resolve_route(deps.keys, Scope(account, companion, None))
    except TrialOver:
        route = getattr(deps.keys, "trial", None)
    if route is None or not route.trial or route.provider != "deepseek":
        return None
    return deepseek_peak_until(now)


async def last_user_at(pool, account: UUID) -> datetime | None:
    return await pool.fetchval("""SELECT max(m.created_at) FROM chat_messages m JOIN conversations c ON c.id = m.user_id
                                  WHERE c.account_id = $1 AND m.role = 'user'""", account)


async def run(deps, rooms, clock, now: datetime) -> str:
    """跑一次日记的钟。返回 written / nothing / no_key / bad / error / waiting / missed / off。"""
    from patrol import store as clock_store
    from patrol.wake import window_for
    pool = deps.pool
    acc, comp = clock.account_id, clock.companion_id
    day, until = date.fromisoformat(clock.spec["day"]), datetime.fromisoformat(clock.spec["until"])
    if now >= until:
        log.info("diary for %s on %s: they never fell asleep before %s", comp, day, until)
        await ensure_clock(pool, acc, now)
        return "missed"
    if not Settings.from_dict(await archive.get_settings(pool, comp)).diary_on:     # 关了：这晚不写，挂明晚
        await ensure_clock(pool, acc, now)
        return "off"
    last = await last_user_at(pool, acc)
    if rooms.busy(await window_for(pool, acc, comp)) or (last is not None and now - last < QUIET):
        await clock_store.reschedule(pool, clock.id, now + RETRY)
        return "waiting"
    if (until_peak := await _free_peak(deps, acc, comp, now)) is not None and until_peak < until:
        await clock_store.reschedule(pool, clock.id, until_peak)       # 免费用户碰上 DeepSeek 高峰：等高峰过了再写（10-01 Tilia）
        return "waiting"
    outcome = await write_day(deps, acc, comp, day, now)
    tries = int(clock.spec.get("tries", 0)) + 1
    if outcome in ("bad", "error") and tries < MAX_TRIES and now + RETRY < until:   # 交卷拆不出 / 模型出错：20 分钟后再来
        await clock_store.set_spec(pool, clock.id, {**clock.spec, "tries": tries})
        await clock_store.reschedule(pool, clock.id, now + RETRY)
        return outcome
    await ensure_clock(pool, acc, now)
    return outcome
