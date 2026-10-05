"""远事 + 抽屉的接口（第 5 步）：远事增删改查、别人的 404；抽屉列表不漏、拆信的 403 / 423 / 409 / 404；导出不漏没拆的信。测试用小满 / Mia。"""
import random
from uuid import UUID

from brain import drawer as D
from test_api import Env


async def lumi(e, c):
    comp, conv = await e.first_window(c)
    return UUID(comp["id"]), UUID(conv["id"])


async def test_dates_crud(pool):
    e = Env(pool)
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        cid, _ = await lumi(e, c)
        r = await c.post(f"/companions/{cid}/dates", json={"day": "2030-12-01", "time": "14:30", "title": "坐飞机"})
        assert r.status_code == 201 and r.json()["title"] == "坐飞机" and r.json()["days_left"] > 0
        did = r.json()["id"]
        assert (await c.post(f"/companions/{cid}/dates", json={"day": "2020-01-01", "title": "过去"})).status_code == 400
        assert (await c.post(f"/companions/{cid}/dates", json={"day": "明天", "title": "x"})).status_code == 400
        r = await c.patch(f"/dates/{did}", json={"day": "2030-12-02", "time": ""})
        assert (r.json()["day"], r.json()["time"]) == ("2030-12-02", "")
        assert [x["id"] for x in (await c.get(f"/companions/{cid}/dates")).json()] == [did]
    async with e.client(other) as c:
        assert (await c.get(f"/companions/{cid}/dates")).status_code == 404
        assert (await c.patch(f"/dates/{did}", json={"title": "偷改"})).status_code == 404
        assert (await c.delete(f"/dates/{did}")).status_code == 404
    async with e.client(t) as c:
        assert (await c.delete(f"/dates/{did}")).status_code == 204
        assert (await c.get(f"/companions/{cid}/dates")).json() == []


async def test_drawer_list_and_open(pool):
    e = Env(pool)
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        cid, _ = await lumi(e, c)
        me = UUID((await c.get("/me")).json()["id"])
        now = e.deps.now()
        a = await D.put(pool, me, cid, title="给你的", content="秘密", unlock_at=None, now=now)
        b = await D.put(pool, me, cid, title="今天的", content="今天拆", unlock_at=None, now=now)
        await pool.execute("UPDATE drawer_letters SET unlock_at = '2020-01-01' WHERE id = $1", b.id)   # 早就到日子了
        rows = (await c.get("/drawer")).json()
        assert {r["id"]: r["openable"] for r in rows} == {a.id: False, b.id: True}
        assert all("content" not in r and "code" not in r and "title" not in r for r in rows)

        assert (await c.post(f"/drawer/{a.id}/open", json={})).status_code == 409          # 没到日子也没钥匙
        code = await D.give_key(pool, cid, a.id, random.Random(3), now)
        wrong = "0000" if code != "0000" else "1111"
        r = await c.post(f"/drawer/{a.id}/open", json={"code": wrong})
        assert r.status_code == 403 and r.json()["left"] == 4
        for _ in range(4):
            r = await c.post(f"/drawer/{a.id}/open", json={"code": wrong})
        assert r.status_code == 423 and r.json()["wait_seconds"] == 600
        r = await c.post(f"/drawer/{b.id}/open", json={})
        assert r.status_code == 200 and r.json()["content"] == "今天拆" and r.json()["from"] == "Lumi"
        assert [x.get("title") for x in (await c.get("/drawer")).json() if x["id"] == b.id] == ["今天的"]
    async with e.client(other) as c:
        assert (await c.get("/drawer")).json() == []
        assert (await c.post(f"/drawer/{b.id}/open", json={})).status_code == 404


async def test_export_keeps_sealed_letters_sealed(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        cid, _ = await lumi(e, c)
        me = UUID((await c.get("/me")).json()["id"])
        await D.put(pool, me, cid, title="锁着的", content="不能偷看", unlock_at=None, now=e.deps.now())
        await c.post(f"/companions/{cid}/dates", json={"day": "2030-12-01", "title": "坐飞机"})
        data = (await c.get("/me/export")).json()
    assert "不能偷看" not in str(data) and "锁着的" not in str(data) and len(data["drawer"]) == 1
    assert data["companions"][0]["far_dates"][0]["title"] == "坐飞机"
