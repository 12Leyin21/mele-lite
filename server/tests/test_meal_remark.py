"""记一餐 Lumi 说一句（09-30，设计 specs/2026-09-30-meal-remark-design.md，Tilia定：默认开、不等估算、每次都说）。
测试用小满编的菜。"""
from datetime import datetime, timedelta, timezone

from brain import archive
from patrol import store
from patrol.loop import tick_once
from test_api import Env

T0 = datetime(2026, 9, 30, 7, 0, tzinfo=timezone.utc)            # 新加坡 15:00
TZ_SG = "Asia/Singapore"


def _all_text(req) -> str:
    return "\n".join([b.text for b in req.system] + [m.text for m in req.messages])


async def _env(pool, script):
    e = Env(pool, script)
    clock = {"now": T0}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    return e, t, clock


async def test_one_remark_for_meals_logged_within_a_minute(pool):
    e, t, clock = await _env(pool, ["早呀，燕麦粥配什么？", "甜筒加奶茶？今天挺凉的哎，别冻着"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "reply_wait": 0, "heartbeat_on": False}})
        await c.put("/me/context/weather", json={"temp_c": 14, "desc": "小雨", "place": "新加坡"})
        clock["now"] = T0 - timedelta(hours=7)                                          # 新加坡 08:00
        await c.post("/food/entry", json={"meal": "早餐", "text": "燕麦粥", "kcal": 320})
        clock["now"] += timedelta(minutes=2)
        await tick_once(e.deps, e.rooms)
        assert "燕麦粥" in _all_text(e.model.requests[-1])

        clock["now"] = T0
        await c.post("/food/entry", json={"meal": "加餐", "text": "甜筒", "kcal": 250})
        clock["now"] += timedelta(seconds=20)
        await c.post("/food/entry", json={"meal": "加餐", "text": "珍珠奶茶", "kcal": 410})
        assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'meal' AND next_at IS NOT NULL") == 1
        clock["now"] = T0 + timedelta(seconds=30)
        await tick_once(e.deps, e.rooms)                                                 # 一分钟还没到：不说
        assert len(e.model.requests) == 1
        clock["now"] = T0 + timedelta(minutes=2)
        await tick_once(e.deps, e.rooms)
        ask = _all_text(e.model.requests[-1])
        assert "甜筒" in ask and "珍珠奶茶" in ask and "15:00" in ask
        assert "燕麦粥" in ask and "08:00" in ask                                         # 今天前面吃过的
        assert "14°C" in ask and "小雨" in ask
        assert "250" not in ask and "410" not in ask and "320" not in ask               # 看不到热量
        from brain.wake_text import MUST_SPEAK
        assert "meal" in MUST_SPEAK                                                      # 一定开口
        msgs = await archive.recent(pool, conv["id"], 5)
        assert msgs[-1].role == "assistant" and "甜筒" in msgs[-1].text
        assert await pool.fetchval("SELECT count(*) FROM push_queue") >= 1
        clock["now"] += timedelta(minutes=5)
        await tick_once(e.deps, e.rooms)                                                 # 说过的不再说
        assert len(e.model.requests) == 2


async def test_switch_off_edits_and_lumi_entries_stay_quiet(pool):
    e, t, clock = await _env(pool, [])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "heartbeat_on": False}})
        assert (await c.get("/food/settings")).json()["remark"] is True                 # 默认开
        await c.put("/food/settings", json={"remark": False})
        await c.post("/food/entry", json={"meal": "午餐", "text": "牛肉面", "kcal": 600})
        assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'meal'") == 0
        await c.put("/food/settings", json={"remark": True})
        await c.post("/food/entry", json={"meal": "运动", "text": "跑步", "kcal": 200, "source": "watch", "ext_id": "w1"})
        eid = (await c.post("/food/entry", json={"meal": "晚餐", "text": "沙拉", "kcal": 300})).json()["id"]
        await pool.execute("DELETE FROM clocks WHERE kind = 'meal'")
        await c.patch(f"/food/entry/{eid}", json={"kcal": 350})                           # 改了一条：不说
        await c.delete(f"/food/entry/{eid}")
        assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'meal'") == 0
        assert await pool.fetchval("SELECT count(*) FROM food_entries WHERE text = '跑步' AND NOT remarked") == 0


async def test_remarks_dont_use_up_the_daily_wake_budget(pool):
    e, t, clock = await _env(pool, ["嗯嗯", "又吃啦"])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "heartbeat_on": False}})
        for text in ("饼干", "酸奶"):
            await c.post("/food/entry", json={"meal": "加餐", "text": text, "kcal": 100})
            clock["now"] += timedelta(minutes=2)
            await tick_once(e.deps, e.rooms)
        assert len(e.model.requests) == 2                                                # 每次都说
        from uuid import UUID
        assert await store.wakes_since(pool, UUID(comp["id"]), T0 - timedelta(hours=1)) == 0


async def test_numbers_wait_for_the_next_normal_turn(pool):
    """说那句的这一轮不给〔饮食〕（有热量）；下一轮 TA 开口时照常告诉它。"""
    e, t, clock = await _env(pool, ["甜筒！", "嗯嗯"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "heartbeat_on": False, "reply_wait": 0}})
        await c.post("/food/entry", json={"meal": "加餐", "text": "甜筒", "kcal": 250})
        clock["now"] += timedelta(minutes=2)
        await tick_once(e.deps, e.rooms)
        assert "〔饮食〕TA 刚记了" not in _all_text(e.model.requests[0])
        from uuid import UUID
        from brain.scope import Scope
        from brain.turn import run_turn

        async def emit(_):
            return None
        me = UUID((await c.get("/me")).json()["id"])
        await run_turn(e.deps, Scope(me, UUID(comp["id"]), UUID(conv["id"])), "好冷", emit)
        assert "〔饮食〕TA 刚记了" in _all_text(e.model.requests[1]) and "250" in _all_text(e.model.requests[1])
