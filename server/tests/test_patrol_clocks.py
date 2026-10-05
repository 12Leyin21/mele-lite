"""钟的纯计算：下一次什么时候响、睡觉段、四档数字（巡逻第 1 步）。"""
import random
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from brain.settings import Settings
from patrol.clocks import LEVELS, in_sleep, next_fire, patrol_numbers, validate_spec

TZ_SG = "Asia/Singapore"
SYD = "Australia/Sydney"


def local(tz, *args):
    return datetime(*args, tzinfo=ZoneInfo(tz))


def as_local(dt, tz):
    return dt.astimezone(ZoneInfo(tz)).replace(tzinfo=None)


# ── 固定时间 ──

def test_at_every_day_today_then_tomorrow():
    spec = validate_spec("at", {"time": "08:00"})
    assert as_local(next_fire("at", spec, local(TZ_SG, 2026, 9, 28, 7, 0), TZ_SG), TZ_SG) == datetime(2026, 9, 28, 8, 0)
    assert as_local(next_fire("at", spec, local(TZ_SG, 2026, 9, 28, 8, 0), TZ_SG), TZ_SG) == datetime(2026, 9, 29, 8, 0)


def test_at_weekdays_skips_weekend():
    spec = validate_spec("at", {"time": "08:00", "days": [0, 1, 2, 3, 4]})     # 周一到周五
    fri_after = local(TZ_SG, 2026, 10, 2, 9, 0)                                  # 2026-10-02 是周五
    assert as_local(next_fire("at", spec, fri_after, TZ_SG), TZ_SG) == datetime(2026, 10, 5, 8, 0)


def test_at_across_dst_keeps_local_time():
    spec = validate_spec("at", {"time": "08:00"})
    before = next_fire("at", spec, local(SYD, 2026, 10, 2, 9, 0), SYD)          # 10-04 凌晨两点拨快
    after = next_fire("at", spec, before, SYD)
    assert as_local(before, SYD) == datetime(2026, 10, 3, 8, 0) and as_local(after, SYD) == datetime(2026, 10, 4, 8, 0)
    assert after - before == timedelta(hours=23)                                 # 夜里少了一小时，墙上的钟照旧八点
    assert before.astimezone(timezone.utc).hour == 22 and after.astimezone(timezone.utc).hour == 21


def test_at_in_the_dst_gap_still_fires_once_that_day():
    spec = validate_spec("at", {"time": "02:30"})                               # 这一刻那天不存在
    t = next_fire("at", spec, local(SYD, 2026, 10, 3, 12, 0), SYD)
    assert t.astimezone(ZoneInfo(SYD)).date().isoformat() == "2026-10-04"
    assert next_fire("at", spec, t, SYD).astimezone(ZoneInfo(SYD)).date().isoformat() == "2026-10-05"


# ── 一次性 ──

def test_once_fires_then_none():
    spec = validate_spec("once", {"at": "2026-10-03 14:00"}, tz=TZ_SG)
    t = next_fire("once", spec, local(TZ_SG, 2026, 10, 1, 0, 0), TZ_SG)
    assert as_local(t, TZ_SG) == datetime(2026, 10, 3, 14, 0)
    assert next_fire("once", spec, t, TZ_SG) is None


def test_once_bad_time_rejected():
    with pytest.raises(ValueError):
        validate_spec("once", {"at": "明天下午"}, tz=TZ_SG)


# ── 每隔几小时 ──

def test_every_two_hours_inside_hours():
    spec = validate_spec("every", {"every_min": 120, "from": "09:00", "to": "21:00"})
    seq, t = [], local(TZ_SG, 2026, 9, 28, 8, 0)
    for _ in range(8):
        t = next_fire("every", spec, t, TZ_SG)
        seq.append(as_local(t, TZ_SG).strftime("%d %H:%M"))
    assert seq == ["28 09:00", "28 11:00", "28 13:00", "28 15:00", "28 17:00", "28 19:00", "28 21:00", "29 09:00"]


def test_every_across_midnight_window():
    spec = validate_spec("every", {"every_min": 180, "from": "22:00", "to": "04:00"})
    seq, t = [], local(TZ_SG, 2026, 9, 28, 21, 0)
    for _ in range(4):
        t = next_fire("every", spec, t, TZ_SG)
        seq.append(as_local(t, TZ_SG).strftime("%d %H:%M"))
    assert seq == ["28 22:00", "29 01:00", "29 04:00", "29 22:00"]


def test_every_too_short_rejected():
    with pytest.raises(ValueError):
        validate_spec("every", {"every_min": 5})


# ── 时间段里随机 ──

def test_window_random_once_per_day():
    spec = validate_spec("window", {"from": "19:00", "to": "22:00"})
    rng = random.Random(7)
    t = next_fire("window", spec, local(TZ_SG, 2026, 9, 28, 10, 0), TZ_SG, rng)
    lt = as_local(t, TZ_SG)
    assert lt.date().isoformat() == "2026-09-28" and 19 <= lt.hour < 22
    t2 = as_local(next_fire("window", spec, t, TZ_SG, rng), TZ_SG)
    assert t2.date().isoformat() == "2026-09-29" and 19 <= t2.hour < 22


def test_window_already_started_goes_to_tomorrow():
    spec = validate_spec("window", {"from": "19:00", "to": "22:00"})
    t = as_local(next_fire("window", spec, local(TZ_SG, 2026, 9, 28, 20, 0), TZ_SG, random.Random(1)), TZ_SG)
    assert t.date().isoformat() == "2026-09-29"


def test_bad_specs_rejected():
    for shape, spec in [("at", {"time": "25:00"}), ("at", {"time": "08:00", "days": [7]}),
                        ("window", {"from": "19:00", "to": "19:00"}), ("nope", {})]:
        with pytest.raises(ValueError):
            validate_spec(shape, spec)


# ── 睡觉段、四档 ──

def test_in_sleep_across_midnight():
    assert in_sleep(local(TZ_SG, 2026, 9, 28, 1, 0), TZ_SG, "23:30", "07:30")
    assert in_sleep(local(TZ_SG, 2026, 9, 28, 23, 45), TZ_SG, "23:30", "07:30")
    assert not in_sleep(local(TZ_SG, 2026, 9, 28, 7, 30), TZ_SG, "23:30", "07:30")
    assert in_sleep(local(TZ_SG, 2026, 9, 28, 3, 0), TZ_SG, "01:00", "09:00")
    assert not in_sleep(local(TZ_SG, 2026, 9, 28, 0, 30), TZ_SG, "01:00", "09:00")


def test_four_levels_and_overrides():
    assert [LEVELS[k].day_gap_min for k in ("low", "mid", "high", "max")] == [240, 120, 60, 30]
    assert [LEVELS[k].night_awake_max for k in ("low", "mid", "high", "max")] == [1, 3, 5, 7]
    assert [LEVELS[k].asleep_gap_min for k in ("low", "mid", "high", "max")] == [0, 180, 90, 45]
    assert [LEVELS[k].daily_cap for k in ("low", "mid", "high", "max")] == [6, 12, 24, 48]
    s = Settings.from_dict({"patrol_level": "high", "patrol_overrides": {"daily_cap": 30}})
    n = patrol_numbers(s)
    assert (n.day_gap_min, n.daily_cap) == (60, 30)
    assert patrol_numbers(Settings()) == LEVELS["mid"]


def test_patrol_settings_validated():
    assert Settings().patrol_level == "mid" and Settings().heartbeat_on is True
    for bad in [{"patrol_level": "extreme"}, {"sleep_from": "7am"}, {"patrol_overrides": {"daily_cap": 0}},
                {"patrol_overrides": {"day_gap_min": 5}}, {"patrol_overrides": {"what": 1}},
                {"patrol_overrides": {"asleep_gap_min": 10}}]:
        with pytest.raises(ValueError):
            Settings.from_dict(bad)
    assert Settings.from_dict({"patrol_overrides": {"asleep_gap_min": 0}}).patrol_overrides == {"asleep_gap_min": 0}
