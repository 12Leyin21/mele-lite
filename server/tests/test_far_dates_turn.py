"""远事第 3 步：remember_date 工具、倒回、易变区那几行、为远事醒来（一定开口）、巡逻顺手自动了结。测试用小满。"""
import json
from datetime import date, timedelta

import memory as M
from brain import archive, rewind
from brain import far_dates as FD
from brain.settings import Settings
from brain.tools import tool_specs
from patrol import store
from patrol.loop import tick_once
from patrol.wake import wake_once
from test_patrol_wake import World
from test_wake_turn import NOW, TZ, go, setup


def add_call(**kw):
    return {"calls": [("remember_date", {"action": "add", **kw})]}


async def test_tool_add_list_done(pool):
    deps, scope, model = await setup(pool, [
        add_call(day="2026-10-10", time="14:30", title="坐飞机", note="去墨尔本"), "好，记着",
        {"calls": [("remember_date", {"action": "list"})]}, {"calls": [("remember_date", {"action": "done", "id": 0})]},
        "太好了"])
    out, ev = await go(deps, scope, "10 月 10 号下午两点半我要坐飞机去墨尔本")
    cards = [(e["kind"], e["text"], e["private"]) for e in ev if e["type"] == "card"]
    assert cards == [("date", "记下了：10/10 坐飞机", False)]
    [f] = await FD.list_open(pool, scope.account, scope.companion)
    assert (f.day, f.at_time, f.title, f.note) == (date(2026, 10, 10), "14:30", "坐飞机", "去墨尔本")
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'date'") == 3
    assert "记下了远事 2026-10-10「坐飞机」" in (await archive.recent(pool, scope.conversation))[-1].tools

    model.script[1] = {"calls": [("remember_date", {"action": "done", "id": f.id, "result": "顺利到了"})]}
    await go(deps, scope, "我到墨尔本啦")
    listing = model.requests[3].rounds[0].results[0]
    assert f"#{f.id} 2026-10-10 14:30 坐飞机（去墨尔本）" in listing
    assert await FD.list_open(pool, scope.account, scope.companion) == []
    assert [m.content for m in await M.list_memories(pool, scope.companion)] == ["2026-10-10 坐飞机：顺利到了"]


async def test_tool_errors_and_update(pool):
    deps, scope, model = await setup(pool, [
        {"calls": [("remember_date", {"action": "add", "day": "2026-09-01", "title": "过去的"}),
                   ("remember_date", {"action": "done", "id": 999, "result": "x"})]}, "嗯"])
    await go(deps, scope, "嗯")
    results = model.requests[1].rounds[0].results
    assert "已经过了" in results[0] and "没有这件" in results[1]
    s = Settings.from_dict({"tz": TZ})
    f = await FD.add(pool, scope.account, scope.companion, s, day=date(2026, 10, 10), title="考试", now=NOW)
    model.script += [{"calls": [("remember_date", {"action": "update", "id": f.id, "day": "2026-10-12"})]}, "改好了"]
    await go(deps, scope, "考试改到 12 号了")
    assert (await FD.get(pool, scope.account, f.id)).day == date(2026, 10, 12)


async def test_rewind_takes_the_date_back(pool):
    deps, scope, _ = await setup(pool, [add_call(day="2026-10-10", title="坐飞机"), "好"])
    await go(deps, scope, "10 号坐飞机")
    user = (await archive.recent(pool, scope.conversation))[0]
    await rewind.rewind_to_user(pool, deps.embedder, scope, user.id)
    assert await FD.list_open(pool, scope.account, scope.companion) == []
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'date'") == 0


def test_not_in_incognito():
    assert "remember_date" in [t.name for t in tool_specs()]
    assert "remember_date" not in [t.name for t in tool_specs(incognito=True)]


async def test_volatile_has_the_near_dates(pool):
    deps, scope, model = await setup(pool, ["嗯嗯"])
    s = Settings.from_dict({"tz": TZ})
    await FD.add(pool, scope.account, scope.companion, s, day=date(2026, 10, 1), title="面试", now=NOW)   # 新加坡今天 9/28
    await FD.add(pool, scope.account, scope.companion, s, day=date(2026, 12, 1), title="太远的", now=NOW)
    await go(deps, scope, "在吗")
    sent = model.requests[0].messages[-1].text
    assert "还有 3 天：10/1 面试" in sent and "太远的" not in sent


async def date_clock(pool, date_id, phase):
    rows = await pool.fetch("SELECT id FROM clocks WHERE kind = 'date' AND (spec->>'date_id')::bigint = $1 "
                            "AND spec->>'phase' = $2", date_id, phase)
    return await store.get_clock(pool, (await pool.fetchval("SELECT account_id FROM clocks WHERE id = $1", rows[0]["id"])),
                                 rows[0]["id"], kinds=("date",))


async def test_wake_for_a_date_must_speak(pool):
    w = await World().build(pool, ["明天面试，早点睡呀"])
    s = Settings.from_dict({"tz": "Asia/Singapore"})
    f = await FD.add(pool, w.acc, w.comp, s, day=date(2026, 9, 29), at_time="10:00", title="面试", now=w.now)
    eve = await date_clock(pool, f.id, "eve")
    w.now = eve.next_at
    assert await wake_once(w.deps, w.rooms, eve, w.now) == "said"
    envelope = w.model.requests[0].messages[-1].text
    assert "这是我帮 TA 记着的日子。一定要开口，只用想说什么。" in envelope
    assert "我记着的事：「明天是 TA 的一件事：面试（10:00）。」" in envelope and "<silent>" not in envelope
    assert await w.log() == [("date", "said")]
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE id = $1", eve.id) == 0      # 响完就删


async def test_after_wake_asks_to_resolve_and_gone_date_does_not_wake(pool):
    w = await World().build(pool, ["面试怎么样呀"])
    s = Settings.from_dict({"tz": "Asia/Singapore"})
    f = await FD.add(pool, w.acc, w.comp, s, day=date(2026, 9, 29), title="面试", now=w.now)
    after = await date_clock(pool, f.id, "after")
    w.now = after.next_at
    await wake_once(w.deps, w.rooms, after, w.now)
    assert "昨天是 TA 的一件事：面试。我想知道怎么样了。问过了就用 remember_date 标了结" in w.model.requests[0].messages[-1].text

    g = await FD.add(pool, w.acc, w.comp, s, day=date(2026, 9, 30), title="考试", now=w.now - timedelta(days=2))
    day = await date_clock(pool, g.id, "day")
    await pool.execute("UPDATE far_dates SET resolved_at = now() WHERE id = $1", g.id)       # 早就聊过、了结了
    assert await wake_once(w.deps, w.rooms, day, day.next_at) == "gone"
    assert len(w.model.requests) == 1 and await pool.fetchval("SELECT count(*) FROM clocks WHERE id = $1", day.id) == 0


async def test_tick_auto_resolves(pool):
    w = await World().build(pool, [])
    s = Settings.from_dict({"tz": "Asia/Singapore"})
    await FD.add(pool, w.acc, w.comp, s, day=date(2026, 9, 28), title="体检", now=w.now)
    await pool.execute("DELETE FROM clocks")                        # 只看自动了结，不让钟来搅
    w.now = w.now + timedelta(days=3)
    await tick_once(w.deps, w.rooms)
    assert await FD.list_open(pool, w.acc, w.comp) == []
    assert [m.content for m in await M.list_memories(pool, w.comp)] == ["2026-09-28 体检"]
