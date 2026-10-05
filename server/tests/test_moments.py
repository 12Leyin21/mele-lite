"""朋友圈（10-01，移植自之前自用的 App）：谁来刷、评论该谁回、联系人互评最多两轮、到点来刷那一小轮、免费用户每天 3 次、接口。测试用小满。"""
import random
from datetime import datetime, timedelta, timezone
from uuid import UUID

from brain import accounts, archive
from brain import moments as MO
from patrol.loop import tick_once
from test_api import Env
from test_stickers import pic

NOW = datetime(2026, 10, 1, 4, 0, tzinfo=timezone.utc)
R = random.Random(1)


async def family(pool):
    acc = await accounts.create_account(pool)
    lumi = await accounts.create_companion(pool, acc)
    lin = await accounts.create_companion(pool, acc)
    for c, n in ((lumi, "Lumi"), (lin, "林晚")):
        await archive.save_persona(pool, c, {"name": n})
        await archive.save_settings(pool, c, {"tz": "Asia/Singapore", "user_name": "小满"})
    return acc, lumi, lin


async def visits(pool):
    return [(str(r["companion_id"]), r["comment_id"] is not None, r["peer"], r["round"])
            for r in await pool.fetch("SELECT * FROM moment_visits ORDER BY id")]


async def test_who_comes_by(pool):
    acc, lumi, lin = await family(pool)
    m = await MO.post(pool, acc, MO.USER, content="今天的晚霞", now=NOW, rng=R)
    rows = await pool.fetch("SELECT companion_id, due_at, peer FROM moment_visits")
    assert {r["companion_id"] for r in rows} == {lumi, lin} and not any(r["peer"] for r in rows)
    assert all(timedelta(minutes=15) <= r["due_at"] - NOW <= timedelta(minutes=180) for r in rows)
    await pool.execute("DELETE FROM moment_visits")
    await MO.post(pool, acc, str(lumi), content="她今天又熬夜", now=NOW, context_note="想她了", rng=R)
    assert await visits(pool) == [(str(lin), False, True, 0)]                       # 别的联系人来刷，peer
    await pool.execute("DELETE FROM moment_visits")
    c1 = await MO.comment(pool, acc, m.id, MO.USER, "好看吧", now=NOW, rng=R)                # 评自己的：没人要回
    assert await visits(pool) == []
    lc = await MO.comment(pool, acc, m.id, str(lumi), "好看", now=NOW, rng=R)
    assert await visits(pool) == []                                                   # 联系人评 TA 的：不排
    await MO.comment(pool, acc, m.id, MO.USER, "你也觉得？", now=NOW, reply_to=lc["id"], rng=R)
    assert await visits(pool) == [(str(lumi), True, False, 0)]                        # 回它的评论：它来回
    assert c1["reply_to"] is None


async def test_companions_talk_at_most_two_rounds(pool):
    acc, lumi, lin = await family(pool)
    m = await MO.post(pool, acc, str(lin), content="书店今天来了只猫", now=NOW, rng=R)
    await pool.execute("DELETE FROM moment_visits")
    a = await MO.comment(pool, acc, m.id, str(lumi), "什么颜色的", now=NOW, round_=0, rng=R)
    assert await visits(pool) == [(str(lin), True, True, 1)]
    b = await MO.comment(pool, acc, m.id, str(lin), "橘的", now=NOW, reply_to=a["id"], round_=1, rng=R)
    assert (await visits(pool))[-1] == (str(lumi), True, True, 2)
    await MO.comment(pool, acc, m.id, str(lumi), "胖吗", now=NOW, reply_to=b["id"], round_=2, rng=R)
    assert len(await visits(pool)) == 2                                               # 第三轮不排了
    await MO.comment(pool, acc, m.id, MO.USER, "我也想看", now=NOW, reply_to=b["id"], rng=R)
    assert (await visits(pool))[-1] == (str(lin), True, False, 0)                     # TA 插话：重新算


async def test_visit_likes_and_comments_quietly(pool):
    e = Env(pool, [{"calls": [("moment_like", {"id": 1}), ("moment_comment", {"id": 1, "content": "这个颜色好温柔"})]}, ""] * 4)
    clock = {"now": NOW}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"heartbeat_on": False, "morning_on": False,
                                                                      "diary_on": False}})
        for i in range(4):
            await c.post("/moments", data={"content": f"第{i}条"})
    acc = await pool.fetchval("SELECT account_id FROM companions")
    await pool.execute("UPDATE moment_visits SET due_at = $1", NOW)
    ids = [r["id"] for r in await pool.fetch("SELECT id FROM moments ORDER BY id")]
    clock["now"] = NOW + timedelta(minutes=1)
    await tick_once(e.deps, e.rooms)
    ask = "\n".join(m.text for m in e.model.requests[0].messages)
    assert "〔朋友圈〕我刷到了 小满（TA）" in ask or "〔朋友圈〕我刷到了" in ask
    assert [x.name for x in e.model.requests[0].tools] == ["moment_comment", "moment_like"]
    statuses = [r["status"] for r in await pool.fetch("SELECT status FROM moment_visits ORDER BY id")]
    assert statuses.count("done") == 3 and statuses.count("skipped") == 1           # 免费每天 3 次
    m1 = await MO.get(pool, acc, ids[0])
    assert m1.likes == [comp["id"]] and m1.comments[0]["content"] == "这个颜色好温柔"
    assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE role = 'assistant'") == 0   # 不进聊天


async def test_api(pool, tmp_path):
    e = Env(pool)
    e.deps.now = lambda: NOW
    t = await e.login()
    e.app.state.api.cfg.files_dir = tmp_path
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        r = await c.post("/moments", data={"content": "晚霞"}, files=[("files", ("a.png", pic(), "image/png"))])
        assert r.status_code == 201 and r.json()["images"] == 1 and r.json()["author"] == "user"
        mid = r.json()["id"]
        assert (await c.post("/moments", data={"content": " "})).status_code == 400
        img = await c.get(f"/moments/{mid}/images/0")
        assert img.status_code == 200 and img.headers["content-type"] == "image/jpeg"
        r = await c.post(f"/moments/{mid}/like", json={"liked": True})
        assert r.json()["likes"] == [{"who": "user", "name": "我"}]
        r = await c.post(f"/moments/{mid}/comments", json={"content": "自己评一下"})
        assert r.status_code == 201 and r.json()["comments"][0]["name"] == "我"
        cid = r.json()["comments"][0]["id"]
        assert len((await c.get("/moments")).json()) == 1
        assert (await c.get("/moments", params={"who": comp["id"]})).json() == []
        assert (await c.get("/moments", params={"who": "nobody"})).status_code == 404
        r = await c.put("/moments/profile/user/signature", json={"signature": "  今天也要  好好吃饭 "})
        assert r.json()["signature"] == "今天也要 好好吃饭"
        p = (await c.get("/moments/profile/user")).json()
        assert p["signature"] == "今天也要 好好吃饭" and not p["has_cover"]
        assert (await c.put("/moments/profile/user/cover", files={"file": ("c.png", pic(), "image/png")})).status_code == 204
        assert (await c.get("/moments/profile/user/cover")).status_code == 200
        assert (await c.get(f"/moments/profile/{comp['id']}")).json()["name"] == "Lumi"
        assert (await c.delete(f"/moments/comments/{cid}")).status_code == 204
        assert (await c.delete(f"/moments/{mid}")).status_code == 204
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/moments")).json() == []
        assert (await c.get(f"/moments/profile/{comp['id']}")).status_code == 404


async def test_chat_tool_posts_and_signs(pool):
    from test_wake_turn import go, setup
    deps, scope, model = await setup(pool, [
        {"calls": [("moments", {"action": "post", "content": "她今天又熬夜写代码。", "note": "心疼"}),
                   ("moments", {"action": "sign", "signature": "在等一个人睡觉"}),
                   ("moment_like", {"id": 1})]}, "去睡"])
    await go(deps, scope, "我还在写")
    res = model.requests[1].rounds[0].results
    assert res[0].startswith("发好了") and res[1] == "签名改成了「在等一个人睡觉」。" and res[2].startswith("没有这个工具")
    [m] = await MO.feed(pool, scope.account)
    assert (m.author, m.context_note) == (str(scope.companion), "心疼")
    assert (await MO.profile(pool, scope.account, str(scope.companion)))["signature"] == "在等一个人睡觉"


async def test_activity(pool):
    acc, lumi, lin = await family(pool)
    m = await MO.post(pool, acc, MO.USER, content="晚霞", now=NOW, rng=R)
    mine = await MO.comment(pool, acc, m.id, MO.USER, "好看吧", now=NOW, rng=R)
    await MO.like(pool, acc, m.id, str(lumi), now=NOW)
    await MO.comment(pool, acc, m.id, str(lumi), "好看", now=NOW + timedelta(minutes=1), rng=R)
    await MO.comment(pool, acc, m.id, str(lin), "嗯嗯", now=NOW + timedelta(minutes=2), reply_to=mine["id"], rng=R)
    await MO.post(pool, acc, str(lin), content="书店的猫", now=NOW + timedelta(minutes=3), rng=R)
    got = await MO.activity(pool, acc, None)
    assert got["new_posts"] == 1 and got["count"] == 3
    assert [i["kind"] for i in got["items"]][:2] == ["comment", "comment"] and got["items"][0]["name"] == "林晚"
    later = await MO.activity(pool, acc, NOW + timedelta(minutes=5))
    assert later["count"] == 0 and later["new_posts"] == 0


def test_deepseek_peak():
    from llm.catalog import deepseek_peak_until
    tue = datetime(2026, 10, 6, 2, 30, tzinfo=timezone.utc)                      # 周二 UTC 02:30 = 高峰
    assert deepseek_peak_until(tue) == datetime(2026, 10, 6, 4, 0, tzinfo=timezone.utc)
    assert deepseek_peak_until(tue.replace(hour=5)) is None
    assert deepseek_peak_until(tue.replace(hour=9, minute=59)) == datetime(2026, 10, 6, 10, 0, tzinfo=timezone.utc)
    assert deepseek_peak_until(datetime(2026, 10, 3, 2, 30, tzinfo=timezone.utc)) is None   # 周六整天平峰


async def test_free_visit_waits_out_deepseek_peak(pool):
    from brain import moment_visit
    from llm.router import Route
    e = Env(pool, [])
    e.deps.keys.trial = Route("deepseek", "ours", "deepseek-flash", "deepseek-flash", trial=True)
    t = await e.login()
    async with e.client(t) as c:
        await c.post("/moments", data={"content": "早"})
    peak = datetime(2026, 10, 6, 2, 30, tzinfo=timezone.utc)
    await pool.execute("UPDATE moment_visits SET due_at = $1", peak)
    await moment_visit.run_due(e.deps, peak)
    row = await pool.fetchrow("SELECT status, due_at FROM moment_visits")
    assert row["status"] == "pending" and row["due_at"] == datetime(2026, 10, 6, 4, 0, tzinfo=timezone.utc)
    assert e.model.requests == []
