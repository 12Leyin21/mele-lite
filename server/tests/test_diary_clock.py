"""日记第 3 步：凌晨的钟——几点开始看、等 TA 睡着、写昨天、到起床还没睡就不写、写完挂明晚、不进醒来账也不推送。测试用小满。"""
from datetime import date, datetime, timedelta, timezone

from brain import archive
from brain import diary as DY
from brain.settings import Settings
from patrol import diary as PD
from patrol.loop import tick_once
from test_api import Env

TZ_SG = "Asia/Singapore"


def utc(y, mo, d, h, mi=0, sec=0):
    return datetime(y, mo, d, h, mi, sec, tzinfo=timezone.utc)


def test_first_check_and_slot():
    s = Settings.from_dict({"tz": TZ_SG, "sleep_from": "23:00", "sleep_to": "07:30"})
    assert PD.first_check(date(2026, 10, 2), s) == utc(2026, 10, 1, 16, 30)                  # 新加坡 00:30
    late = Settings.from_dict({"tz": TZ_SG, "sleep_from": "02:00", "sleep_to": "10:00"})
    assert PD.first_check(date(2026, 10, 2), late) == utc(2026, 10, 1, 18, 45)               # 02:45
    at, day, until = PD.next_slot(utc(2026, 10, 1, 12), s)                                     # 新加坡 10/1 20:00
    assert (at, day, until) == (utc(2026, 10, 1, 16, 30), date(2026, 10, 1), utc(2026, 10, 1, 23, 30))
    assert PD.next_slot(utc(2026, 10, 1, 17), s)[1] == date(2026, 10, 2)                      # 过了 00:30 = 明晚写 10/2


async def chatting(e, c, clock, text):
    comp, conv = await e.first_window(c)
    await archive.add_message(e.pool, conv["id"], "user", text, now=clock["now"])
    return comp, conv


async def test_waits_for_sleep_then_writes_yesterday(pool):
    e = Env(pool, ["〔正文〕她今天去试镜了。\n〔锁着〕无"])
    clock = {"now": utc(2026, 10, 1, 12)}                                                      # 新加坡 10/1 20:00
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "sleep_from": "23:00",
                                                                      "sleep_to": "07:30", "heartbeat_on": False,
                                                                      "morning_on": False}})
        await pool.execute("DELETE FROM clocks WHERE kind = 'diary'")
        await tick_once(e.deps, e.rooms)
        assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 1, 16, 30)
        clock["now"] = utc(2026, 10, 1, 15, 50)                                                  # 23:50 还在说
        await archive.add_message(pool, conv["id"], "user", "我下午去试镜了，晚安", now=clock["now"])
        clock["now"] = utc(2026, 10, 1, 16, 30, 5)
        await tick_once(e.deps, e.rooms)
        assert await DY.companion_entry(pool, comp["id"], date(2026, 10, 1)) is None              # 才 40 分钟，不写
        assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 1, 16, 50, 5)
        clock["now"] = utc(2026, 10, 1, 16, 51)
        await tick_once(e.deps, e.rooms)
    entry = await DY.companion_entry(pool, comp["id"], date(2026, 10, 1))
    assert entry.body == "她今天去试镜了。"
    assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 2, 16, 30)
    assert await pool.fetchval("SELECT count(*) FROM wake_log") == 0
    assert await pool.fetchval("SELECT count(*) FROM push_queue") == 0
    assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE role <> 'user'") == 0


async def test_never_slept_skips_the_night(pool):
    e = Env(pool, [])
    clock = {"now": utc(2026, 10, 1, 12)}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "sleep_from": "23:00",
                                                                      "sleep_to": "07:30", "heartbeat_on": False,
                                                                      "morning_on": False}})
        await pool.execute("DELETE FROM clocks WHERE kind = 'diary'")
        await tick_once(e.deps, e.rooms)
        t0 = utc(2026, 10, 1, 16, 30, 5)
        for i in range(25):                                                                     # 一整晚每 20 分钟都在说话
            clock["now"] = t0 + timedelta(minutes=20 * i)
            await archive.add_message(pool, conv["id"], "user", f"还没睡{i}", now=clock["now"] - timedelta(minutes=1))
            await tick_once(e.deps, e.rooms)
    assert await DY.companion_entry(pool, comp["id"], date(2026, 10, 1)) is None
    assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 2, 16, 30)
    assert e.model.requests == []


async def test_bad_answers_retry_at_most_three_times(pool):
    e = Env(pool, ["忘了格式"] * 3)
    clock = {"now": utc(2026, 10, 1, 12)}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "sleep_from": "23:00",
                                                                      "sleep_to": "07:30", "heartbeat_on": False,
                                                                      "morning_on": False}})
        await archive.add_message(pool, conv["id"], "user", "晚安", now=clock["now"])
        await pool.execute("DELETE FROM clocks WHERE kind = 'diary'")
        await tick_once(e.deps, e.rooms)
        for i in range(4):
            clock["now"] = utc(2026, 10, 1, 16, 31) + timedelta(minutes=21 * i)
            await tick_once(e.deps, e.rooms)
    assert len(e.model.requests) == 3
    assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 2, 16, 30)


async def test_switched_off_writes_nothing(pool):
    e = Env(pool, [])
    clock = {"now": utc(2026, 10, 1, 12)}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "sleep_from": "23:00", "sleep_to": "07:30",
                                                                      "heartbeat_on": False, "morning_on": False,
                                                                      "diary_on": False}})
        await archive.add_message(pool, conv["id"], "user", "晚安", now=clock["now"])
        await pool.execute("DELETE FROM clocks WHERE kind = 'diary'")
        await tick_once(e.deps, e.rooms)
        clock["now"] = utc(2026, 10, 1, 16, 31)
        await tick_once(e.deps, e.rooms)
    assert e.model.requests == [] and await DY.companion_entry(pool, comp["id"], date(2026, 10, 1)) is None
    assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 2, 16, 30)


async def test_free_diary_waits_out_deepseek_peak(pool):
    """美国作息：洛杉矶凌晨 00:30 = UTC 07:30，周二正好是 DeepSeek 高峰 → 挪到 UTC 10:00 再写。"""
    from llm.router import Route
    e = Env(pool, ["〔正文〕平常的一天。\n〔锁着〕无"])
    e.deps.keys.trial = Route("deepseek", "ours", "deepseek-flash", "deepseek-flash", trial=True)
    clock = {"now": utc(2026, 10, 5, 22)}                                    # 洛杉矶 10/5 周一 15:00
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "America/Los_Angeles", "sleep_from": "23:00",
                                                                      "sleep_to": "07:30", "heartbeat_on": False,
                                                                      "morning_on": False}})
        await archive.add_message(pool, conv["id"], "user", "晚安", now=clock["now"])
        await pool.execute("DELETE FROM clocks WHERE kind = 'diary'")
        await tick_once(e.deps, e.rooms)
        assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 6, 7, 30)
        clock["now"] = utc(2026, 10, 6, 7, 31)
        await tick_once(e.deps, e.rooms)
        assert e.model.requests == []
        assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'diary'") == utc(2026, 10, 6, 10, 0)
        clock["now"] = utc(2026, 10, 6, 10, 0, 30)
        await tick_once(e.deps, e.rooms)
    assert (await DY.companion_entry(pool, comp["id"], date(2026, 10, 5))).body == "平常的一天。"
