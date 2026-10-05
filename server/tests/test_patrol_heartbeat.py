"""心跳的第一道门（巡逻第 2 步）：免费的判断，放不放它醒、为什么醒。"""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from patrol.clocks import LEVELS
from patrol.heartbeat import CHECK_EVERY, NIGHT_AWAKE_GAP, Facts, backoff, gate

TZ = "Asia/Singapore"
MID = LEVELS["mid"]          # 白天 2h、深夜醒着 3 次、睡着 3h、一天 12 次


def at(h, m=0, day=28):
    return datetime(2026, 9, day, h, m, tzinfo=ZoneInfo(TZ))


def facts(now, **kw):
    base = dict(now=now, tz=TZ, sleep_from="00:00", sleep_to="08:00", last_said_at=None, last_woke_at=None,
                last_active_at=None, wakes_today=0, night_found=0, quiet_streak=0, busy=False)
    base.update(kw)
    return Facts(**base)


def test_day_whim_after_gap():
    v = gate(facts(at(15), last_said_at=at(12, 59)), MID)
    assert v.wake and v.reason == "whim"
    assert not gate(facts(at(15), last_said_at=at(13, 30)), MID).wake
    assert v.next_check == at(15) + CHECK_EVERY


def test_gap_counts_from_last_wake_too():
    assert not gate(facts(at(15), last_said_at=at(9), last_woke_at=at(14)), MID).wake


def test_never_talked_is_a_whim():
    assert gate(facts(at(15)), MID).reason == "whim"


def test_busy_and_cap_block():
    assert gate(facts(at(15), busy=True), MID).blocked == "busy"
    v = gate(facts(at(15), wakes_today=12), MID)
    assert not v.wake and v.blocked == "cap"


def test_night_awake_until_max():
    kw = dict(last_said_at=at(0, 10), last_active_at=at(1, 55))
    v = gate(facts(at(2), **kw), MID)
    assert v.wake and v.reason == "night_awake"
    assert not gate(facts(at(2), night_found=3, **kw), MID).wake
    assert not gate(facts(at(0, 30), last_said_at=at(0, 10), last_active_at=at(0, 29)), MID).wake   # 不到 30 分钟


def test_asleep_gap_and_low_level_never():
    v = gate(facts(at(4), last_said_at=at(0, 59)), MID)
    assert v.wake and v.reason == "asleep"
    assert not gate(facts(at(3), last_said_at=at(0, 59)), MID).wake              # 不到 3 小时
    assert not gate(facts(at(4), last_said_at=at(0, 59)), LEVELS["low"]).wake    # 低档睡着不叫


def test_active_long_ago_counts_as_asleep():
    v = gate(facts(at(4), last_said_at=at(0, 59), last_active_at=at(3, 40)), MID)
    assert v.reason == "asleep"


def test_sleep_window_across_midnight():
    kw = dict(sleep_from="23:00", sleep_to="07:00", last_said_at=at(20, 0, day=27))
    assert gate(facts(at(23, 30, day=27), **kw), MID).reason == "asleep"
    assert gate(facts(at(7, 30), **kw), MID).reason == "whim"


def test_backoff_after_five_quiet_wakes():
    assert [backoff(n) for n in (0, 4, 5, 9, 10, 30)] == [1, 1, 2, 2, 4, 4]
    kw = dict(last_said_at=at(12))
    assert gate(facts(at(14, 30), quiet_streak=4, **kw), MID).wake
    assert not gate(facts(at(14, 30), quiet_streak=5, **kw), MID).wake          # 要 4 小时了
    assert gate(facts(at(16, 1), quiet_streak=5, **kw), MID).wake


def test_night_awake_gap_constant():
    assert NIGHT_AWAKE_GAP == timedelta(minutes=30) and CHECK_EVERY == timedelta(minutes=20)
