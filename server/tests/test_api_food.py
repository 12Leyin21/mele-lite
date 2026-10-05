"""饮食的接口（09-29）：按账号隔开、按天汇总、只记录模式、一餐多张照片、导出、删号。测试用小满 / Mia 编的菜。"""
import io
from uuid import UUID

from PIL import Image

from test_api import Env


def _jpg() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), (200, 120, 60)).save(buf, "JPEG")
    return buf.getvalue()


async def test_entries_day_summary_and_goal(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        r = await c.post("/food/entry", json={"meal": "早餐", "text": "燕麦粥", "kcal": 320, "protein": 12, "day": "2026-09-29"})
        assert r.status_code == 201 and r.json()["status"] == "manual"
        await c.post("/food/entry", json={"meal": "运动", "text": "跑步", "detail": "30 分钟", "kcal": 250, "day": "2026-09-29"})
        await c.post("/food/entry", json={"meal": "午餐", "text": "番茄炒蛋饭", "day": "2026-09-29"})     # 没数 = 待估
        from food import estimate
        await estimate.drain()                               # 假模型没剧本：估不出来，留着 pending
        d = (await c.get("/food/day/2026-09-29")).json()
        assert [x["text"] for x in d["entries"]] == ["燕麦粥", "跑步", "番茄炒蛋饭"]
        assert d["entries"][2]["status"] == "pending" and d["targets"] is None                 # 默认只记录
        assert (d["summary"]["net"], d["summary"]["pending"]) == (70, 1) and "remaining" not in d["summary"]
        s = (await c.put("/food/settings", json={"goal": "keep", "height_cm": 170, "weight_kg": 65, "age": 28,
                                                  "sex": "f", "activity": "light"})).json()
        assert s["goal"] == "keep" and s["targets"]["kcal"] > 1500
        d = (await c.get("/food/day/2026-09-29")).json()
        assert d["summary"]["remaining"] == s["targets"]["kcal"] - 70
        days = (await c.get("/food/days")).json()
        assert days[0]["date"] == "2026-09-29" and "燕麦粥" in days[0]["blurb"] and days[0]["pending"] == 1
        eid = d["entries"][0]["id"]
        assert (await c.patch(f"/food/entry/{eid}", json={"kcal": 350})).json()["kcal"] == 350
        assert (await c.delete(f"/food/entry/{eid}")).status_code == 204
        assert len((await c.get("/food/day/2026-09-29")).json()["entries"]) == 2
        assert (await c.post("/food/entry", json={"meal": "宵夜", "text": "x"})).status_code == 400


async def test_many_photos_per_meal_and_isolation(pool):
    e = Env(pool)
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        ids = [(await c.post("/food/photo", files={"file": (f"p{i}.jpg", _jpg(), "image/jpeg")})).json()["id"] for i in range(3)]
        r = await c.post("/food/entry", json={"meal": "晚餐", "text": "火锅", "kcal": 900, "photos": ids, "day": "2026-09-29"})
        eid = r.json()["id"]
        assert [p["id"] for p in r.json()["photos"]] == ids                                      # 不限张数，照顺序
        r = await c.patch(f"/food/entry/{eid}", json={"photos": [ids[2], ids[0]]})
        assert [p["id"] for p in r.json()["photos"]] == [ids[2], ids[0]]
        assert (await c.get(f"/attachments/{ids[1]}")).status_code == 200
    async with e.client(other) as c:
        assert (await c.get("/food/day/2026-09-29")).json()["entries"] == []                     # Mia 看不到小满的
        assert (await c.patch(f"/food/entry/{eid}", json={"kcal": 1})).status_code == 404
        assert (await c.delete(f"/food/entry/{eid}")).status_code == 404
        assert (await c.post("/food/entry", json={"meal": "午餐", "text": "偷图", "photos": [ids[0]]})).status_code == 400
    async with e.client(t) as c:
        exported = (await c.get("/me/export")).json()
        assert [x["text"] for x in exported["food"]["entries"]] == ["火锅"]
        me = UUID((await c.get("/me")).json()["id"])
        assert (await c.request("DELETE", "/me", json={"confirm": True})).status_code in (200, 204)
    assert await pool.fetchval("SELECT count(*) FROM food_entries WHERE account_id = $1", me) == 0


async def _settled(e, c, day="2026-09-29"):
    from food import estimate
    await estimate.drain()
    return (await c.get(f"/food/day/{day}")).json()["entries"]


async def test_background_estimate_text_photos_and_failures(pool):
    from llm.router import Route
    e = Env(pool, ['{"kcal": 650, "protein": 28, "carbs": 80, "fat": 22, "portion": "约 500g", "note": "一大碗"}',
                   '{"kcal": 900, "protein": 40, "carbs": 70, "fat": 50, "note": "看图：锅底 + 肥牛"}',
                   "这个我不太确定诶"])
    e.deps.caption_route = Route("gemini", "ours", "cap-model", "cap-model")     # 看图走我们的
    t = await e.login()
    async with e.client(t) as c:
        r = await c.post("/food/entry", json={"meal": "午餐", "text": "牛肉面", "detail": "加了个蛋", "day": "2026-09-29"})
        assert r.json()["status"] == "pending"                                       # 接口马上回，后台估
        [x] = await _settled(e, c)
        assert (x["status"], x["kcal"], x["protein"], x["note"]) == ("estimated", 650, 28, "一大碗")
        assert "牛肉面" in e.model.requests[0].messages[0].text and not e.model.requests[0].messages[0].images
        ids = [(await c.post("/food/photo", files={"file": (f"p{i}.jpg", _jpg(), "image/jpeg")})).json()["id"] for i in range(2)]
        await c.post("/food/entry", json={"meal": "晚餐", "text": "火锅", "photos": ids, "day": "2026-09-29"})
        ents = await _settled(e, c)
        assert ents[1]["kcal"] == 900 and e.model.requests[1].model == "cap-model"
        assert len(e.model.requests[1].messages[0].images) == 2                       # 两张一起看
        await c.post("/food/entry", json={"meal": "加餐", "text": "一杯奶茶", "day": "2026-09-29"})
        ents = await _settled(e, c)
        assert ents[2]["status"] == "failed" and "手填" in ents[2]["note"]
        used = await pool.fetchval("SELECT count(*) FROM usage_daily")
        assert used >= 1
        await pool.execute("UPDATE accounts SET trial_micro = 0, trial_day = '2999-01-01'")     # 免费额度用完了
        await c.post("/food/entry", json={"meal": "加餐", "text": "一个苹果", "day": "2026-09-29"})
        ents = await _settled(e, c)
        assert ents[3]["status"] == "pending" and "额度" in ents[3]["note"] and len(e.model.requests) == 3


async def test_food_tool_and_the_one_time_note(pool):
    # 09-29：Lumi 一把 food 工具；〔饮食〕只在 TA 刚记 / 刚估好的下一轮出现一次
    from datetime import datetime, timezone
    from brain.tools import _TOOLS, ToolContext
    from food import store as S
    e = Env(pool, ["好的", "嗯嗯"])
    t = await e.login()
    async with e.client(t) as c:
        me = UUID((await c.get("/me")).json()["id"])
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        ctx = ToolContext(pool=pool, embedder=None, user_id=UUID(comp["id"]), account_id=me,
                          now=datetime(2026, 9, 29, 5, tzinfo=timezone.utc))
        food = _TOOLS["food"][1]
        out = await food(ctx, {"action": "add", "items": [{"meal": "午餐", "text": "牛肉面", "kcal": 650},
                                                           {"meal": "加餐", "text": "香蕉", "kcal": 100}]})
        assert "记好了 2 条" in out
        day = (await food(ctx, {"action": "day"}))
        assert "牛肉面" in day and "750" in day
        eid = (await S.entries_on(pool, me, datetime(2026, 9, 29).date()))[1]["id"]
        assert "删了" in await food(ctx, {"action": "delete", "id": eid})
        assert "没有这条" in await food(ctx, {"action": "delete", "id": 999999})
        assert "查不了" in await food(ctx, {"action": "lookup", "q": "oat milk"})          # 没接查营养的传输
        assert await pool.fetchval("SELECT bool_and(told) FROM food_entries WHERE source = 'lumi'")   # 它自己记的不用再告诉它
        await c.post("/food/entry", json={"meal": "晚餐", "text": "番茄炒蛋饭", "kcal": 700})         # TA 自己记的
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我吃完饭了"})
        await e.rooms.idle(UUID(conv["id"]))
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗯"})
        await e.rooms.idle(UUID(conv["id"]))
    first, second = e.model.requests[0].messages[-1].text, e.model.requests[1].messages[-1].text
    assert "〔饮食〕" in first and "番茄炒蛋饭" in first and "700" in first
    assert "〔饮食〕" not in second
    assert "food" in [t.name for t in e.model.requests[0].tools]


async def test_watch_import_dedupes_and_deleted_stay_deleted(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        w = {"meal": "运动", "text": "跑步", "detail": "32 分钟", "kcal": 280, "source": "watch", "ext_id": "hk-1", "day": "2026-09-29"}
        r = await c.post("/food/entry", json=w)
        assert r.status_code == 201 and r.json()["source"] == "watch"
        assert (await c.post("/food/entry", json=w)).status_code == 400                   # 同一个 ext_id 只记一次
        await c.delete(f"/food/entry/{r.json()['id']}")
        assert (await c.post("/food/entry", json=w)).status_code == 400                   # 删过的不再导回


async def test_photo_only_meal_gets_named(pool):
    from llm.router import Route
    e = Env(pool, ['{"kcal": 520, "protein": 20, "carbs": 60, "fat": 18, "note": "看图", "name": "牛肉拉面"}'])
    e.deps.caption_route = Route("gemini", "ours", "cap-model", "cap-model")
    t = await e.login()
    async with e.client(t) as c:
        pid = (await c.post("/food/photo", files={"file": ("p.jpg", _jpg(), "image/jpeg")})).json()["id"]
        await c.post("/food/entry", json={"meal": "晚餐", "text": "拍的这一餐", "photos": [pid], "day": "2026-09-29"})
        [x] = await _settled(e, c)
    assert (x["text"], x["kcal"]) == ("牛肉拉面", 520) and '"name"' in e.model.requests[0].messages[0].text


async def test_estimate_learns_from_past_corrections_and_knows_where(pool):
    """Tilia 09-29：甜筒估 300、实际 180~200。TA 手改过的数带进下一次估算当参考；按 TA 所在地的常见份量估。"""
    e = Env(pool, ['{"kcal": 300, "protein": 5, "carbs": 40, "fat": 12, "portion": "约 150g", "note": "一个甜筒"}',
                   '{"kcal": 210, "protein": 4, "carbs": 30, "fat": 8, "note": "参考了之前的甜筒"}'])
    t = await e.login()
    async with e.client(t) as c:
        comp, _conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore"}})
        await c.post("/food/entry", json={"meal": "加餐", "text": "甜筒", "day": "2026-09-29"})
        [x] = await _settled(e, c)
        assert x["kcal"] == 300
        assert "Asia/Singapore" in e.model.requests[0].messages[0].text          # 按当地份量
        assert "改过" not in e.model.requests[0].messages[0].text                  # 还没改过，不提
        await c.patch(f"/food/entry/{x['id']}", json={"kcal": 190})               # TA 手改
        await c.post("/food/entry", json={"meal": "加餐", "text": "冰淇淋", "day": "2026-09-29"})
        await _settled(e, c)
        ask = e.model.requests[1].messages[0].text
        assert "甜筒" in ask and "300" in ask and "190" in ask
        await c.put("/food/settings", json={"country": "nz"})                    # 设置里写了国家就用它
        await c.post("/food/entry", json={"meal": "加餐", "text": "苹果", "kcal": 80, "day": "2026-09-29"})
        from food import estimate
        rows = await estimate.corrections(pool, UUID((await c.get("/me")).json()["id"]))
        assert [(r["text"], r["est_kcal"], r["kcal"]) for r in rows] == [("甜筒", 300, 190)]   # 手填的苹果不算改过


async def test_corrections_skip_tiny_changes_and_exercise(pool):
    e = Env(pool, ['{"kcal": 500, "note": "x"}', '{"kcal": 250}'])
    t = await e.login()
    async with e.client(t) as c:
        await c.post("/food/entry", json={"meal": "午餐", "text": "三明治", "day": "2026-09-29"})
        await c.post("/food/entry", json={"meal": "运动", "text": "跑步", "detail": "30 分钟", "day": "2026-09-29"})
        a, b = await _settled(e, c)
        await c.patch(f"/food/entry/{a['id']}", json={"kcal": 480})               # 差不到一成，不算
        await c.patch(f"/food/entry/{b['id']}", json={"kcal": 350})               # 运动不当吃的参考
        from food import estimate
        assert await estimate.corrections(pool, UUID((await c.get("/me")).json()["id"])) == []
