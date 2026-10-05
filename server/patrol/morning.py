"""起床前醒来准备（10-01 Tilia点头，设计 specs/2026-10-01-morning-prep-design.md；Instinct 借的）。

每个账号一个早上的钟（挂在主联系人上，跟每日私选同一个），起床时间前 30 分钟响：它把 TA 今天的事过一遍，
想好 TA 醒来看到的第一句，**静音推送**（不吵醒 TA）。一定要开口；不占「每天主动找几次」的份。
推歌是默认时间（起床后半小时）的，今天的歌合进这一次，推歌的钟挪到明天。
周末先不分（作息只有一个起床时间）。开关是主联系人设置里的 morning_on（10-01 Tilia：跟心跳分开——
关了心跳只是不想它随时冒出来，早上照样要；关了早上、开着心跳，它照样想你了就来，只是没有每天固定那一次）。"""
from __future__ import annotations

from datetime import date, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from brain import accounts, archive
from brain.settings import Settings

BEFORE_WAKE = timedelta(minutes=30)


def next_time(now: datetime, s: Settings) -> datetime:
    """下一次：起床时间前半小时，按 TA 的时区；今天过了就明天。"""
    tz = ZoneInfo(s.tz)
    h, m = (int(x) for x in s.sleep_to.split(":"))
    at = (datetime.combine(date(2000, 1, 2), time(h, m)) - BEFORE_WAKE).time()
    local = now.astimezone(tz)
    t = datetime.combine(local.date(), at, tzinfo=tz)
    return t if t > local else t + timedelta(days=1)


async def ensure_clock(pool, account: UUID, now: datetime) -> None:
    """这个账号的早上钟：删掉重挂（时间按现在的作息重算）；没联系人就不挂。"""
    from patrol import store as clock_store
    comps = await accounts.list_companions(pool, account)
    await pool.execute("DELETE FROM clocks WHERE account_id = $1 AND kind = 'morning'", account)
    if not comps:
        return
    s = Settings.from_dict(await archive.get_settings(pool, comps[0]))
    at = next_time(now, s)
    await clock_store.add_clock(pool, account, comps[0], kind="morning", shape="once", spec={"at": at.isoformat()},
                                note="", next_at=at)


async def ensure_all(pool, now: datetime) -> int:
    """巡逻每趟顺手补：有联系人、还没有早上钟的账号挂一个。返回挂了几个。"""
    rows = await pool.fetch("""SELECT DISTINCT c.account_id FROM companions c
                               WHERE NOT EXISTS (SELECT 1 FROM clocks k WHERE k.account_id = c.account_id AND k.kind = 'morning')""")
    for r in rows:
        await ensure_clock(pool, r["account_id"], now)
    return len(rows)
