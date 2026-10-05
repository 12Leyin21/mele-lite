"""收藏夹（10-02）：收一句、收一组、收过的不重收、取消、无痕不收、别人的收不了、窗口删了收藏还在。测试用小满。"""
from uuid import UUID

from test_api import Env


async def _said(e, c, conv, text):
    await c.post(f"/conversations/{conv['id']}/messages", json={"text": text})
    await e.rooms.idle(UUID(conv["id"]))
    return (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]


async def test_favorites_roundtrip(pool):
    e = Env(pool, ["记得带伞", "晚安"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        msgs = await _said(e, c, conv, "明天下雨吗")
        mine, its = msgs[0], msgs[1]
        r = await c.post("/favorites", json={"items": [{"message_id": its["id"], "slot": 16, "text": "记得带伞"}]})
        assert r.status_code == 201 and r.json()[0]["mine"] is False and r.json()[0]["group_id"] is None
        assert r.json()[0]["companion_id"] == comp["id"] and r.json()[0]["conversation_id"] == conv["id"]
        again = await c.post("/favorites", json={"items": [{"message_id": its["id"], "slot": 16, "text": "记得带伞"}]})
        assert again.json() == []                                                   # 收过的跳过

        msgs = await _said(e, c, conv, "好")
        group = [{"message_id": m["id"], "slot": 16 if m["role"] == "assistant" else 0, "text": m["text"]} for m in msgs[2:]]
        g = (await c.post("/favorites", json={"items": group, "group": True})).json()
        assert len(g) == 2 and g[0]["group_id"] and g[0]["group_id"] == g[1]["group_id"]
        assert [f["mine"] for f in g] == [True, False]

        listed = (await c.get("/favorites")).json()
        assert len(listed) == 3
        assert (await c.post("/favorites", json={"items": [{"message_id": 999999999, "slot": 0}]})).status_code == 400

        assert (await c.delete(f"/favorites/bubble/{its['id']}/16")).status_code == 204
        assert (await c.delete(f"/favorites/bubble/{its['id']}/16")).status_code == 404
        assert (await c.delete(f"/favorites/group/{g[0]['group_id']}")).status_code == 204
        assert (await c.get("/favorites")).json() == []

        await c.post("/favorites", json={"items": [{"message_id": mine["id"], "slot": 0, "text": "明天下雨吗"}]})
        export = (await c.get("/me/export")).json()
        assert [f["text"] for f in export["favorites"]] == ["明天下雨吗"]

    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/favorites")).json() == []
        r = await c.post("/favorites", json={"items": [{"message_id": mine["id"], "slot": 0}]})
        assert r.status_code == 400                                                # 别人的话收不了
        fid = (await pool.fetchval("SELECT id FROM favorites LIMIT 1"))
        assert (await c.delete(f"/favorites/{fid}")).status_code == 404


async def test_incognito_is_not_kept(pool):
    e = Env(pool, ["嗯"])
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        inc = (await c.post(f"/companions/{comp['id']}/conversations", json={"incognito": True})).json()
        msgs = await _said(e, c, inc, "悄悄话")
        r = await c.post("/favorites", json={"items": [{"message_id": msgs[0]["id"], "slot": 0, "text": "悄悄话"}]})
        assert r.status_code == 400 and "无痕" in r.json()["detail"]
