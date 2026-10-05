"""巡逻的接口（第 6 步）。登录、造人都借 test_api 的 Env。测试用小满 / Mia。"""
from zoneinfo import ZoneInfo
from datetime import datetime, timedelta, timezone
from uuid import UUID

from brain import archive
from patrol import store
from patrol.estimate import levels_table, wakes_per_day
from patrol.clocks import LEVELS
from test_api import Env


async def lumi(e, c):
    comp, conv = await e.first_window(c)
    return UUID(comp["id"]), UUID(conv["id"])


async def test_user_clocks_crud_and_self_clocks_hidden(pool):
    e = Env(pool)
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        cid, _ = await lumi(e, c)
        await c.patch(f"/companions/{cid}", json={"settings": {"tz": "Asia/Singapore"}})
        r = await c.post(f"/companions/{cid}/clocks", json={"shape": "at", "spec": {"time": "08:00", "days": [0, 1, 2, 3, 4]},
                                                           "note": "问我今天的安排"})
        assert r.status_code == 201 and r.json()["next_at"] and r.json()["spec"]["days"] == [0, 1, 2, 3, 4]
        clock_id = r.json()["id"]
        bad = await c.post(f"/companions/{cid}/clocks", json={"shape": "once", "spec": {"at": "2020-01-01 08:00"}})
        assert bad.status_code == 400 and "过了" in bad.json()["detail"]
        assert (await c.post(f"/companions/{cid}/clocks", json={"shape": "every", "spec": {"every_min": 3}})).status_code == 400
        r = await c.patch(f"/clocks/{clock_id}", json={"note": "提醒吃药", "spec": {"time": "21:30"}})
        assert r.json()["note"] == "提醒吃药" and r.json()["spec"] == {"time": "21:30", "days": []}
        me = UUID((await c.get("/me")).json()["id"])
        secret = await store.add_clock(pool, me, cid, kind="self", shape="once", spec={"at": "2030-01-01T00:00:00+00:00"},
                                       note="问问面试", next_at=datetime(2030, 1, 1, tzinfo=timezone.utc))
        listed = (await c.get(f"/companions/{cid}/clocks")).json()
        assert [x["note"] for x in listed] == ["提醒吃药"]                          # 它约的不出现
        assert (await c.patch(f"/clocks/{secret.id}", json={"note": "偷看"})).status_code == 404
        assert (await c.delete(f"/clocks/{secret.id}")).status_code == 404
    async with e.client(other) as c:
        assert (await c.get(f"/companions/{cid}/clocks")).status_code == 404
        assert (await c.delete(f"/clocks/{clock_id}")).status_code == 404
    async with e.client(t) as c:
        assert (await c.delete(f"/clocks/{clock_id}")).status_code == 204


async def test_active_sets_time_zone_and_unpauses(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        cid, _ = await lumi(e, c)
        me = UUID((await c.get("/me")).json()["id"])
        await store.ensure_heartbeat(pool, me, cid, datetime.now(timezone.utc))
        await pool.execute("UPDATE clocks SET spec = '{\"errors\": 3, \"paused\": true}'::jsonb WHERE kind = 'heartbeat'")
        r = (await c.post("/me/active", json={"tz": "Europe/Paris"})).json()
        assert r["notice"] and "不主动找你" in r["notice"]
        assert (await c.post("/me/active", json={})).json()["notice"] is None       # 只说一次
        assert (await c.get(f"/companions/{cid}")).json()["settings"]["tz"] == "Europe/Paris"
        assert (await c.post("/me/active", json={"tz": "Mars/Base"})).status_code == 400
        assert (await c.post("/me/devices", json={"apns_token": "abc123"})).status_code == 204
        assert (await c.post("/me/devices", json={"apns_token": "abc123"})).status_code == 204
    assert await pool.fetchval("SELECT last_active_at FROM accounts WHERE id = $1", me) is not None
    assert await pool.fetchval("SELECT spec FROM clocks WHERE kind = 'heartbeat'") == "{}"
    assert await pool.fetchval("SELECT count(*) FROM devices") == 1


async def test_wake_log_endpoint(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        cid, conv = await lumi(e, c)
        me = UUID((await c.get("/me")).json()["id"])
        now = datetime.now(timezone.utc)
        for outcome, reason, cost in [("said", "whim", 0.002), ("silent", "asleep", 0.001), ("skipped_cap", "user", 0)]:
            await store.log_wake(pool, account=me, companion=cid, conversation=conv, at=now, reason=reason, clock_id=None,
                                 outcome=outcome, cost_usd=cost, detail={"note": "交房租"} if reason == "user" else None)
        r = (await c.get(f"/companions/{cid}/wakes")).json()
    assert r["today"] == {"woke": 2, "said": 1, "cost_usd": 0.003}
    assert len(r["items"]) == 3 and r["skipped_user_clocks"][0]["note"] == "交房租"


async def test_wake_log_carries_what_it_said(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        cid, conv = await lumi(e, c)
        await c.patch(f"/companions/{cid}", json={"settings": {"tz": "Asia/Singapore"}})
        me = UUID((await c.get("/me")).json()["id"])
        now = datetime.now(timezone.utc)
        msg = await archive.add_message(pool, conv, "assistant", "诶，房租交了没\n\n别又拖到周末", now=now)
        await store.log_wake(pool, account=me, companion=cid, conversation=conv, at=now, reason="whim", clock_id=None,
                             outcome="said", cost_usd=0.002, message_id=msg.id)
        await store.log_wake(pool, account=me, companion=cid, conversation=conv, at=now, reason="whim", clock_id=None,
                             outcome="silent", cost_usd=0.001)
        await store.log_wake(pool, account=me, companion=cid, conversation=conv, at=now, reason="whim", clock_id=None,
                             outcome="said", cost_usd=0.002, message_id=999999999)      # 那条后来被倒回删了
        r = (await c.get(f"/companions/{cid}/wakes")).json()
    said = [i for i in r["items"] if i["outcome"] == "said"]
    assert {i["text"] for i in said} == {"诶，房租交了没\n\n别又拖到周末", None}
    hit = next(i for i in said if i["text"])
    assert hit["message_id"] == msg.id and hit["conversation_id"] == str(conv)
    day = now.astimezone(ZoneInfo("Asia/Singapore")).date().isoformat()
    assert r["silent_by_day"] == {day: 1}


def test_estimate_numbers():
    assert [wakes_per_day(LEVELS[k], "00:00", "08:00") for k in ("low", "mid", "high", "max")] == [4, 10, 21, 42]
    t = levels_table("deepseek-flash", 0.001, "00:00", "08:00")
    assert t["mid"] == {"wakes_per_month": 300, "usd_per_month": 0.3}
    assert levels_table("no-such-model", None, "00:00", "08:00")["mid"]["usd_per_month"] is None


async def test_estimate_endpoint(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        cid, _ = await lumi(e, c)
        r = (await c.get(f"/companions/{cid}/patrol/estimate")).json()
        assert r["model"] == "fake-chat" and r["levels"]["mid"]["usd_per_month"] is None       # 试用的假模型算不出钱
        kid = (await c.post("/keys", json={"provider": "deepseek", "api_key": "sk-mia-abcdef9876",
                                           "chat_model": "deepseek-flash"})).json()["id"]
        await c.patch(f"/companions/{cid}", json={"key_id": kid, "settings": {"patrol_level": "high"}})
        r = (await c.get(f"/companions/{cid}/patrol/estimate")).json()
    assert r["model"] == "deepseek-flash" and r["per_wake_usd"] > 0
    assert r["current"]["level"] == "high" and r["current"]["wakes_per_month"] == 630
    assert r["levels"]["max"]["usd_per_month"] > r["levels"]["low"]["usd_per_month"]


async def test_focus_start_end_and_told_once(pool):
    e = Env(pool, ["1. 刷一下就回来\n2. 诶，说好的呢\n3. 五分钟了哦\n4. 我真生气了\n5. 放下手机！", "加油，学完了吗", "嗯嗯"])
    t = await e.login()
    async with e.client(t) as c:
        cid, conv = await lumi(e, c)
        await c.patch(f"/companions/{cid}", json={"settings": {"reply_wait": 0}})
        assert (await c.post(f"/conversations/{conv}/focus/start", json={"minutes": 1})).status_code == 400
        r = await c.post(f"/conversations/{conv}/focus/start", json={"minutes": 30, "label": "背单词"})
        assert r.status_code == 201 and r.json()["lines"] == ["刷一下就回来", "诶，说好的呢", "五分钟了哦", "我真生气了", "放下手机！"]
        fid = r.json()["id"]
        assert "30 分钟（背单词）" in e.model.requests[0].messages[0].text
        assert (await c.post(f"/focus/{fid}/end", json={"distracted_times": 2, "distracted_minutes": 4})).status_code == 204
        assert (await c.post(f"/focus/{fid}/end", json={})).status_code == 404       # 结束过了
        await c.post(f"/conversations/{conv}/messages", json={"text": "我学完啦"})
        await e.rooms.idle(conv)
        await c.post(f"/conversations/{conv}/messages", json={"text": "嗯"})
        await e.rooms.idle(conv)
    first, second = e.model.requests[1].messages[-1].text, e.model.requests[2].messages[-1].text
    assert "〔专注〕刚才 TA 专注了 30 分钟（背单词），中途分心 2 次、一共 4 分钟。" in first
    assert "〔专注〕" not in second


async def test_focus_without_a_key_still_gets_lines(pool):
    e = Env(pool)
    t = await e.login(device_id="phone-9")
    async with e.client(t) as c:
        cid, conv = await lumi(e, c)
        await pool.execute("UPDATE accounts SET trial_micro = 0, trial_day = '2999-01-01'")   # 额度用完、今天不会再补
        r = await c.post(f"/conversations/{conv}/focus/start", json={"minutes": 25})
    assert r.status_code == 201 and len(r.json()["lines"]) == 5 and e.model.requests == []


async def test_catch_up_hides_the_wake_envelope(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        _, conv = await lumi(e, c)
        await archive.add_message(pool, conv, "wake", "〔醒来〕……")
        await archive.add_message(pool, conv, "assistant", "诶，在干嘛呢")
        r = (await c.get(f"/conversations/{conv}/messages")).json()["messages"]
        preview = (await c.get(f"/companions/{(await e.first_window(c))[0]['id']}/conversations")).json()[0]["preview"]
    assert [m["role"] for m in r] == ["assistant"] and preview == "诶，在干嘛呢"


async def test_focus_lumi_decides_when_to_lock_and_early_end(pool):
    # 09-29 Tilia：允许 Lumi 锁时，它写提醒时顺便定「刷到第几条还不停就锁」；提前结束的，〔专注〕那行说一声
    e = Env(pool, ["刷一下就回来\n诶，说好的呢\n五分钟了哦\n我真生气了\n放下手机！\n锁：3\n看一下：你昨天还说这周要把单词背完呢", "学得怎么样", "嗯"])
    t = await e.login()
    async with e.client(t) as c:
        cid, conv = await lumi(e, c)
        await c.patch(f"/companions/{cid}", json={"settings": {"reply_wait": 0}})
        r = await c.post(f"/conversations/{conv}/focus/start", json={"minutes": 45, "label": "背单词", "allow_lock": True})
        assert r.json()["lock_after"] == 3 and len(r.json()["lines"]) == 5 and "锁" not in "".join(r.json()["lines"])
        assert "锁：" in e.model.requests[0].messages[0].text and "看一下：" in e.model.requests[0].messages[0].text
        assert r.json()["peek_line"] == "你昨天还说这周要把单词背完呢" and "看一下" not in "".join(r.json()["lines"])
        fid = r.json()["id"]
        await pool.execute("UPDATE focus_sessions SET started_at = now() - interval '20 minutes' WHERE id = $1", UUID(fid))
        assert (await c.post(f"/focus/{fid}/end", json={"distracted_times": 1, "distracted_minutes": 1, "early": True})).status_code == 204
        await c.post(f"/conversations/{conv}/messages", json={"text": "我不学了"})
        await e.rooms.idle(conv)
    assert "提前结束了，专注了 20 分钟" in e.model.requests[1].messages[-1].text


def test_parse_lock():
    from brain.focus import parse_lines, parse_lock
    assert parse_lock("a\nb\n锁：2") == 2 and parse_lock("a\nLock: 5") == 5
    assert parse_lock("a\n锁：9") == 0 and parse_lock("a\nb") == 0 and parse_lock("锁：不锁") == 0
    assert parse_lines("一\n二\n锁：2") == ["一", "二"]


async def test_focus_without_allow_lock_never_asks(pool):
    e = Env(pool, ["一\n二\n三\n四\n五"])
    t = await e.login()
    async with e.client(t) as c:
        _, conv = await lumi(e, c)
        r = await c.post(f"/conversations/{conv}/focus/start", json={"minutes": 30})
    assert r.json()["lock_after"] == 0 and "锁：" not in e.model.requests[0].messages[0].text
    assert r.json()["peek_line"] == "" and "看一下：" not in e.model.requests[0].messages[0].text


async def test_focus_said_goes_into_the_chat_once(pool):
    # 09-29 Tilia：专注时手机替它弹的提醒、「我就看一下」那句，也要进聊天流——TA 看得见，它自己也知道说过
    e = Env(pool, ["刷一下就回来\n诶，说好的呢\n五分钟了哦\n我真生气了\n放下手机！", "回来啦", "嗯"])
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        cid, conv = await lumi(e, c)
        await c.patch(f"/companions/{cid}", json={"settings": {"reply_wait": 0}})
        fid = (await c.post(f"/conversations/{conv}/focus/start", json={"minutes": 30})).json()["id"]
        await pool.execute("UPDATE focus_sessions SET started_at = now() - interval '20 minutes' WHERE id = $1", UUID(fid))
        now = datetime.now(timezone.utc)
        items = [{"key": "t1", "at": (now - timedelta(minutes=9)).isoformat(), "text": "刷一下就回来"},
                 {"key": "peek-1", "at": (now - timedelta(minutes=5)).isoformat(), "text": "你昨天还说要背完呢"},
                 {"key": "t9", "at": (now - timedelta(days=3)).isoformat(), "text": "  "}]          # 空的不存
        r = await c.post(f"/focus/{fid}/said", json={"items": items})
        assert r.status_code == 200 and r.json()["added"] == 2
        assert (await c.post(f"/focus/{fid}/said", json={"items": items})).json()["added"] == 0   # 再报一次不重复
        msgs = (await c.get(f"/conversations/{conv}/messages")).json()["messages"]
        said = [m for m in msgs if m["role"] == "assistant"]
        assert [m["text"] for m in said] == ["刷一下就回来", "你昨天还说要背完呢"]
        assert datetime.fromisoformat(said[0]["at"]) < datetime.fromisoformat(said[1]["at"]) < now
        assert (await c.post(f"/focus/{fid}/end", json={"distracted_times": 1, "distracted_minutes": 1})).status_code == 204
        late = {"key": "t2", "at": (now + timedelta(hours=5)).isoformat(), "text": "诶，说好的呢"}   # 结束后才报的也收；时间不会跑到现在以后
        assert (await c.post(f"/focus/{fid}/said", json={"items": [late]})).json()["added"] == 1
        await c.post(f"/conversations/{conv}/messages", json={"text": "我回来了"})
        await e.rooms.idle(conv)
    hist = e.model.requests[1].messages
    assert [m.text for m in hist if m.role == "assistant"][-3:] == ["刷一下就回来", "你昨天还说要背完呢", "诶，说好的呢"]
    assert "手机替你弹给 TA 的那几句" in hist[-1].text
    async with e.client(other) as c:
        assert (await c.post(f"/focus/{fid}/said", json={"items": items})).status_code == 404
