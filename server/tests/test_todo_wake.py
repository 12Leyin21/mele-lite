"""待办第 2 步：到点提醒、进出地方提醒、两个都填（到点人在那儿才提醒，不在就等当天进出）、打过勾跳过、防抖、不占每天的份。测试用小满。"""
from datetime import datetime, timedelta, timezone

from brain import todos as T
from patrol.loop import tick_once
from test_api import Env

TZ_SG = "Asia/Singapore"
NOW = datetime(2026, 10, 1, 4, 0, tzinfo=timezone.utc)             # 新加坡 10/1 周四 12:00


async def world(pool, script):
    e = Env(pool, script)
    clock = {"now": NOW}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {
            "tz": TZ_SG, "heartbeat_on": False, "morning_on": False, "diary_on": False, "reply_wait": 0}})
    acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", comp["id"])
    return e, clock, acc, comp["id"]


def asks(e):
    return ["\n".join(m.text for m in r.messages) for r in e.model.requests]


async def test_timed_todo_reminds_urgently(pool):
    e, clock, acc, comp = await world(pool, ["写作业啦，三点了"])
    await T.create(pool, acc, comp, what="写作业", shape="at", spec={"time": "15:00", "days": [3]}, now=NOW)
    clock["now"] = datetime(2026, 10, 1, 7, 0, 5, tzinfo=timezone.utc)                       # 周四 15:00
    await tick_once(e.deps, e.rooms)
    assert any("TA 的待办：写作业（定的时间到了）" in a and "一定要开口" in a for a in asks(e))
    row = await pool.fetchrow("SELECT urgent, text FROM push_queue ORDER BY id DESC LIMIT 1")
    assert row["urgent"] and row["text"].startswith("写作业啦")
    nxt = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'todo'")
    assert nxt == datetime(2026, 10, 8, 7, 0, tzinfo=timezone.utc)                           # 下周四


async def test_done_this_week_skips(pool):
    e, clock, acc, comp = await world(pool, [])
    t = await T.create(pool, acc, comp, what="写作业", shape="at", spec={"time": "15:00", "days": [3]}, now=NOW)
    await T.set_done(pool, acc, t.id, True, NOW)
    clock["now"] = datetime(2026, 10, 1, 7, 0, 5, tzinfo=timezone.utc)
    await tick_once(e.deps, e.rooms)
    assert e.model.requests == []
    assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'todo'") == datetime(2026, 10, 8, 7, 0, tzinfo=timezone.utc)


async def test_place_only_reminds_each_time_until_done(pool):
    e, clock, acc, comp = await world(pool, ["放学啦，记得买东西", "又出来了？东西买了没"])
    school = await T.add_place(pool, acc, name="学校", lat=0, lon=0)
    t = await T.create(pool, acc, comp, what="买东西", place_id=school.id, place_on="leave", now=NOW)
    assert await T.place_event(pool, acc, school.id, True, NOW) == []                        # 进学校：不是「离开」
    clock["now"] = NOW + timedelta(hours=3)
    assert await T.place_event(pool, acc, school.id, False, clock["now"]) == [t.id]
    await tick_once(e.deps, e.rooms)
    assert any("TA 的待办：买东西（TA 刚离开学校）" in a for a in asks(e))
    assert await T.place_event(pool, acc, school.id, False, clock["now"] + timedelta(minutes=5)) == []   # 边上抖：不重复
    clock["now"] += timedelta(days=1)
    await T.place_event(pool, acc, school.id, True, clock["now"] - timedelta(hours=6))      # 第二天去上学
    assert await T.place_event(pool, acc, school.id, False, clock["now"]) == [t.id]         # 放学离开：照样提醒
    await tick_once(e.deps, e.rooms)
    assert len([a for a in asks(e) if "TA 的待办：买东西" in a]) == 2
    await T.set_done(pool, acc, t.id, True, clock["now"])
    await T.place_event(pool, acc, school.id, True, clock["now"] + timedelta(hours=20))
    assert await T.place_event(pool, acc, school.id, False, clock["now"] + timedelta(days=1)) == []
    await T.place_event(pool, acc, school.id, True, clock["now"] + timedelta(days=2), sync=True)
    assert await T.set_done(pool, acc, t.id, False, clock["now"]) and \
        await T.place_event(pool, acc, school.id, False, clock["now"] + timedelta(days=2), sync=True) == []   # 对状态不提醒
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'todo'") == 0      # 一次性的提醒钟响完就删


async def test_time_and_place_waits_for_the_place(pool):
    e, clock, acc, comp = await world(pool, ["到超市了，顺便买牛奶"])
    shop = await T.add_place(pool, acc, name="超市", lat=0, lon=0)
    await T.place_event(pool, acc, shop.id, False, NOW)
    t = await T.create(pool, acc, comp, what="买牛奶", shape="at", spec={"time": "17:00", "days": [3]},
                       place_id=shop.id, place_on="arrive", now=NOW)
    assert await T.place_event(pool, acc, shop.id, True, NOW + timedelta(minutes=1)) == []   # 还没到点：进超市不算
    await T.place_event(pool, acc, shop.id, False, NOW + timedelta(minutes=2))
    clock["now"] = datetime(2026, 10, 1, 9, 0, 5, tzinfo=timezone.utc)                       # 17:00 人不在超市
    await tick_once(e.deps, e.rooms)
    assert e.model.requests == []
    assert (await T.get(pool, acc, t.id)).waiting_until == datetime(2026, 10, 1, 16, 0, tzinfo=timezone.utc)   # 等到当天结束
    clock["now"] = datetime(2026, 10, 1, 10, 30, tzinfo=timezone.utc)                         # 18:30 进了超市
    assert await T.place_event(pool, acc, shop.id, True, clock["now"]) == [t.id]
    await tick_once(e.deps, e.rooms)
    assert any("TA 的待办：买牛奶（TA 刚到了超市）" in a for a in asks(e))


async def test_time_and_place_already_there(pool):
    e, clock, acc, comp = await world(pool, ["在超市吧？买牛奶"])
    shop = await T.add_place(pool, acc, name="超市", lat=0, lon=0)
    await T.create(pool, acc, comp, what="买牛奶", shape="at", spec={"time": "17:00", "days": []},
                   place_id=shop.id, place_on="arrive", now=NOW)
    await T.place_event(pool, acc, shop.id, True, NOW)
    clock["now"] = datetime(2026, 10, 1, 9, 0, 5, tzinfo=timezone.utc)
    await tick_once(e.deps, e.rooms)
    assert any("TA 的待办：买牛奶（定的时间到了）" in a for a in asks(e))


async def test_old_user_clock_becomes_todo_and_still_fires(pool):
    from patrol import store as clock_store
    e, clock, acc, comp = await world(pool, ["交房租！"])
    at = NOW + timedelta(hours=1)
    await clock_store.add_clock(pool, acc, comp, kind="user", shape="once", spec={"at": at.isoformat()}, note="交房租",
                                next_at=at)
    await tick_once(e.deps, e.rooms)
    assert [x.what for x in await T.list_all(pool, acc)] == ["交房租"]
    clock["now"] = at + timedelta(seconds=5)
    await tick_once(e.deps, e.rooms)
    assert any("TA 的待办：交房租" in a for a in asks(e))
