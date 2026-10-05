"""记着的远事（09-28 远事 + 抽屉第 1 步）：三次醒来的时间、易变区那几行。测试用小满。"""
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

import pytest

from brain.far_dates import FarDate, lines, wake_times

TZ_SG = "Asia/Singapore"
SYDNEY = "Australia/Sydney"


def local(dt: datetime, tz: str) -> str:
    return f"{dt.astimezone(ZoneInfo(tz)):%m-%d %H:%M}"


def times(day, at_time="", *, tz=TZ_SG, sleep_from="23:30", sleep_to="07:30",
          now=datetime(2026, 9, 1, tzinfo=timezone.utc)):
    return [(phase, local(t, tz)) for phase, t in wake_times(day, at_time, tz, sleep_from, sleep_to, now)]


def test_three_wakes_with_a_time():
    # 前一晚：睡前两小时；当天：提前三小时；第二天：下午三点
    assert times(date(2026, 12, 1), "14:30") == [("eve", "11-30 21:30"), ("day", "12-01 11:30"), ("after", "12-02 15:00")]


def test_three_wakes_without_a_time():
    assert times(date(2026, 12, 1)) == [("eve", "11-30 21:30"), ("day", "12-01 08:30"), ("after", "12-02 15:00")]


def test_bedtime_after_midnight_still_the_night_before():
    # 一点睡：「前一晚」是 11/30 夜里 23:00，不是 12/1 的凌晨
    assert times(date(2026, 12, 1), sleep_from="01:00")[0] == ("eve", "11-30 23:00")


@pytest.mark.parametrize("at_time, want", [
    ("09:00", "12-01 08:00"),    # 提前三小时是 06:00，比起床后半小时早 → 挪到 08:00
    ("06:00", "12-01 05:30"),    # 起床前就要出发：挪到起床后会过了点，改成提前半小时
    ("20:00", "12-01 17:00"),
])
def test_day_wake_moves_after_getting_up(at_time, want):
    got = dict(times(date(2026, 12, 1), at_time, sleep_to="07:30"))
    assert got["day"] == want


def test_already_passed_ones_are_dropped():
    now = datetime(2026, 12, 1, 2, 0, tzinfo=timezone.utc)          # 新加坡 12/1 10:00
    assert times(date(2026, 12, 1), "14:30", now=now) == [("day", "12-01 11:30"), ("after", "12-02 15:00")]
    assert times(date(2026, 12, 1), "", now=now) == [("after", "12-02 15:00")]


def test_across_dst_keeps_wall_time():
    # 悉尼 2026-10-04 凌晨两点拨快一小时：墙上的钟说了算
    got = times(date(2026, 10, 4), "12:00", tz=SYDNEY, sleep_from="23:00", sleep_to="07:00")
    assert got == [("eve", "10-03 21:00"), ("day", "10-04 09:00"), ("after", "10-05 15:00")]


def fd(i, day, title, at_time=""):
    return FarDate(id=i, account_id=None, companion_id=None, day=day, at_time=at_time, title=title, note="",
                   created_at=None, resolved_at=None, result="")


def test_lines_zh():
    today = date(2026, 11, 28)
    ds = [fd(1, date(2026, 12, 1), "坐飞机"), fd(2, date(2026, 11, 28), "面试", "14:30"),
          fd(3, date(2026, 11, 27), "考试"), fd(4, date(2026, 11, 29), "妈妈生日"),
          fd(5, date(2026, 12, 12), "交论文"), fd(6, date(2026, 12, 13), "太远了"), fd(7, date(2026, 11, 26), "前天的")]
    assert lines(ds, today, "zh") == ["昨天：考试（还没问怎么样）", "今天：面试（14:30）", "明天：妈妈生日",
                                      "还有 3 天：12/1 坐飞机", "还有 14 天：12/12 交论文"]


def test_lines_at_most_five_and_english():
    today = date(2026, 11, 28)
    ds = [fd(i, date(2026, 11, 29 + i % 2), f"事{i}") for i in range(8)]
    assert len(lines(ds, today, "zh")) == 5
    en = lines([fd(1, date(2026, 12, 1), "flight", "14:30"), fd(2, date(2026, 11, 28), "interview")], today, "en")
    assert en == ["Today: interview", "In 3 days: Dec 1 flight (14:30)"]


# ── 第 2 步：读写、排钟、了结 ──

from datetime import timedelta

import memory as M
from brain import accounts, archive
from brain import far_dates as FD
from brain.settings import Settings
from memory.embed import FakeEmbedder

NOW = datetime(2026, 11, 20, 4, 0, tzinfo=timezone.utc)          # 新加坡 11/20 12:00
S = Settings.from_dict({"tz": TZ_SG, "sleep_from": "23:30", "sleep_to": "07:30"})


async def people(pool):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    return acc, comp


async def date_clocks(pool, date_id):
    rows = await pool.fetch("SELECT spec, next_at FROM clocks WHERE kind = 'date' AND (spec->>'date_id')::bigint = $1 "
                            "ORDER BY next_at", date_id)
    return [(__import__("json").loads(r["spec"])["phase"], local(r["next_at"], TZ_SG)) for r in rows]


async def test_add_schedules_three_clocks(pool):
    acc, comp = await people(pool)
    f = await FD.add(pool, acc, comp, S, day=date(2026, 12, 1), at_time="14:30", title="坐飞机", note="去墨尔本", now=NOW)
    assert (f.title, f.at_time, f.note) == ("坐飞机", "14:30", "去墨尔本")
    assert await date_clocks(pool, f.id) == [("eve", "11-30 21:30"), ("day", "12-01 11:30"), ("after", "12-02 15:00")]
    assert [x.id for x in await FD.list_open(pool, acc, comp)] == [f.id]


async def test_add_rejects_bad_input(pool):
    acc, comp = await people(pool)
    for kw in ({"day": date(2026, 11, 19), "title": "昨天的"}, {"day": date(2026, 12, 1), "title": " "},
               {"day": date(2026, 12, 1), "title": "x", "at_time": "25:00"}, {"day": date(2026, 12, 1), "title": "长" * 61}):
        with pytest.raises(ValueError):
            await FD.add(pool, acc, comp, S, now=NOW, **kw)
    other, _ = await people(pool)
    with pytest.raises(PermissionError):
        await FD.add(pool, other, comp, S, day=date(2026, 12, 1), title="别人的", now=NOW)


async def test_update_reschedules_and_delete_takes_clocks(pool):
    acc, comp = await people(pool)
    f = await FD.add(pool, acc, comp, S, day=date(2026, 12, 1), title="坐飞机", now=NOW)
    g = await FD.update(pool, acc, f.id, S, day=date(2026, 12, 5), at_time="09:00", now=NOW)
    assert (g.day, g.at_time, g.title) == (date(2026, 12, 5), "09:00", "坐飞机")
    assert await date_clocks(pool, f.id) == [("eve", "12-04 21:30"), ("day", "12-05 08:00"), ("after", "12-06 15:00")]
    assert (await FD.update(pool, acc, f.id, S, title="坐飞机去墨尔本", now=NOW)).title == "坐飞机去墨尔本"
    assert len(await date_clocks(pool, f.id)) == 3                  # 只改标题不重排
    other, _ = await people(pool)
    assert await FD.update(pool, other, f.id, S, title="偷改", now=NOW) is None
    assert not await FD.delete(pool, other, f.id)
    assert await FD.delete(pool, acc, f.id)
    assert await date_clocks(pool, f.id) == [] and await FD.list_open(pool, acc, comp) == []
    assert await M.list_memories(pool, comp) == []                 # TA 删的不存记忆


async def test_resolve_saves_a_memory_and_clears_clocks(pool):
    acc, comp = await people(pool)
    f = await FD.add(pool, acc, comp, S, day=date(2026, 12, 1), title="坐飞机", now=NOW)
    done = await FD.resolve(pool, FakeEmbedder(), acc, f.id, "顺利，没晚点", now=NOW + timedelta(days=12))
    assert done.resolved_at is not None and done.result == "顺利，没晚点"
    assert await date_clocks(pool, f.id) == [] and await FD.list_open(pool, acc, comp) == []
    assert [m.content for m in await M.list_memories(pool, comp)] == ["2026-12-01 坐飞机：顺利，没晚点"]
    assert await FD.resolve(pool, FakeEmbedder(), acc, f.id, "再来一次", now=NOW) is None      # 了结过的不再了结


async def test_auto_resolve_only_the_stale_ones(pool):
    acc, comp = await people(pool)
    await archive.save_settings(pool, comp, {"tz": TZ_SG})
    old = await FD.add(pool, acc, comp, S, day=date(2026, 11, 21), title="面试", now=NOW)
    new = await FD.add(pool, acc, comp, S, day=date(2026, 11, 22), title="考试", now=NOW)
    later = datetime(2026, 11, 23, 16, 30, tzinfo=timezone.utc)      # 新加坡 11/24 00:30：面试 +3 天到了，考试没到
    assert await FD.auto_resolve(pool, FakeEmbedder(), later) == 1
    assert [x.id for x in await FD.list_open(pool, acc, comp)] == [new.id]
    assert [m.content for m in await M.list_memories(pool, comp)] == ["2026-11-21 面试"]
    assert (await FD.get(pool, acc, old.id)).resolved_at is not None
