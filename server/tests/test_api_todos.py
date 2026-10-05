"""待办第 3 步：/todos、/places、/places/{id}/event。测试用小满。"""
from datetime import datetime, timezone

from test_api import Env

NOW = datetime(2026, 10, 1, 4, 0, tzinfo=timezone.utc)             # 新加坡 10/1 周四 12:00


async def test_todos_and_places(pool):
    e = Env(pool)
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore"}})
        r = await c.post("/places", json={"name": "学校", "lat": -31.98, "lon": 115.82})
        assert r.status_code == 201 and r.json()["radius"] == 150 and r.json()["inside"] is None
        school = r.json()["id"]
        assert (await c.post("/places", json={"name": "", "lat": 0, "lon": 0})).status_code == 400
        r = await c.post("/todos", json={"what": "买东西", "place_id": school, "place_on": "leave"})
        assert r.status_code == 201
        buy = r.json()
        assert (buy["place"], buy["place_on"], buy["when"], buy["repeat"], buy["done"]) == ("学校", "leave", "", "once", False)
        assert buy["companion_id"] == comp["id"]
        r = await c.post("/todos", json={"what": "写作业", "shape": "at", "spec": {"time": "15:00", "days": [1]}})
        hw = r.json()
        assert (hw["when"], hw["repeat"]) == ("每周二 15:00", "week")
        assert (await c.post("/todos", json={"what": "x", "place_id": school})).status_code == 400
        assert (await c.post("/todos", json={"what": ""})).status_code == 400
        r = await c.post(f"/todos/{hw['id']}/done", json={"done": True})
        assert r.json()["done"]
        rows = (await c.get("/todos")).json()
        assert [x["what"] for x in rows] == ["买东西", "写作业"]                     # 没做完的在前
        r = await c.patch(f"/todos/{buy['id']}", json={"place_on": "arrive", "what": "买牛奶"})
        assert (r.json()["what"], r.json()["place_on"]) == ("买牛奶", "arrive")
        r = await c.patch(f"/todos/{buy['id']}", json={"place_id": None})
        assert r.json()["place"] is None
        r = await c.post(f"/places/{school}/event", json={"inside": True})
        assert r.status_code == 200 and r.json() == {"reminding": []}
        assert (await c.get("/places")).json()[0]["inside"] is True
        assert (await c.post(f"/places/{school}/event", json={})).status_code == 400
        assert (await c.delete(f"/todos/{hw['id']}")).status_code == 204
        assert (await c.delete(f"/places/{school}")).status_code == 204
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/todos")).json() == []
        assert (await c.patch(f"/todos/{buy['id']}", json={"what": "偷改"})).status_code == 404
        assert (await c.post(f"/places/{school}/event", json={"inside": True})).status_code == 404
