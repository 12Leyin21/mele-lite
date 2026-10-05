"""表情包第 3 步：/stickers 接口、从聊天里的图收、从面板发（它看到的是〔表情包：描述〕，不另给原图）。测试用小满。"""
from uuid import UUID

from llm.router import Route
from test_api import Env
from test_stickers import pic


async def test_library_and_sending(pool, tmp_path):
    e = Env(pool, ["哈哈你好得意", "嗯"])
    e.deps.keys.trial = Route("anthropic", "ours", "fake-chat", "fake-ledger", trial=True)     # 会看图的一家
    t = await e.login()
    e.app.state.api.cfg.files_dir = tmp_path
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        r = await c.post("/stickers", files=[("files", ("a.png", pic((1, 1, 1)), "image/png")),
                                             ("files", ("b.gif", pic((2, 2, 2), "GIF", 2), "image/gif")),
                                             ("files", ("a2.png", pic((1, 1, 1)), "image/png")),
                                             ("files", ("x.txt", b"hello", "text/plain"))])
        body = r.json()
        assert r.status_code == 201 and len(body["added"]) == 2
        assert [s["reason"] for s in body["skipped"]] == ["已经收过了", "这个文件不是图片"]
        sid = body["added"][0]["id"]
        r = await c.patch(f"/stickers/{sid}", json={"caption": "一只叉腰的猫，很得意", "name": "得意",
                                                    "only_for": [comp["id"]]})
        assert r.json()["only_for"] == [comp["id"]] and r.json()["name"] == "得意"
        assert (await c.patch(f"/stickers/{sid}", json={"only_for": ["not-a-uuid"]})).status_code == 400
        img = await c.get(f"/stickers/{sid}/image")
        assert img.status_code == 200 and img.headers["content-type"] == "image/png"
        assert len((await c.get("/stickers")).json()) == 2

        att = (await c.post(f"/conversations/{conv['id']}/stickers/{sid}")).json()
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "", "attachments": [att["id"]]})
        await e.rooms.idle(UUID(conv["id"]))
        last = e.model.requests[-1].messages[-1]
        assert "〔TA 发了一个表情包：一只叉腰的猫，很得意〕" in last.text and not last.images
        assert await pool.fetchval("SELECT use_count FROM stickers WHERE id = $1", sid) == 1

        photo = (await c.post(f"/conversations/{conv['id']}/attachments",
                              files={"file": ("p.png", pic((9, 9, 9)), "image/png")})).json()
        r = await c.post(f"/stickers/from-attachment/{photo['id']}")
        assert r.status_code == 201 and len((await c.get("/stickers")).json()) == 3
        assert (await c.delete(f"/stickers/{sid}")).status_code == 204
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/stickers")).json() == []
        assert (await c.get(f"/stickers/{body['added'][1]['id']}/image")).status_code == 404
        assert (await c.post(f"/stickers/from-attachment/{photo['id']}")).status_code == 404
