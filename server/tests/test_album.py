"""相册（10-02，照之前自用的 App）：TA 加照片 → 一分钟后它一小轮写字（不进聊天）、三本（隐私默认不给）、取图、删；
聊天里它 keep TA 刚发的图；翻旧照片。测试用小满。"""
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

from brain import album as AL
from llm.router import Route
from patrol.loop import tick_once
from test_api import Env
from test_stickers import pic

NOW = datetime(2026, 10, 1, 4, 0, tzinfo=timezone.utc)
QUIET = {"heartbeat_on": False, "morning_on": False, "diary_on": False}


async def test_user_adds_photos_and_it_writes(pool, tmp_path):
    e = Env(pool, [{"calls": [("album_write", {"id": 0, "caption": "x"})]}, ""])      # 剧本下面按真编号改
    clock = {"now": NOW}
    e.deps.now = lambda: clock["now"]
    e.app.state.api.cfg.files_dir = tmp_path
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": QUIET})
        r = await c.post("/album", data={"note": "海边的傍晚"},
                         files=[("files", ("a.png", pic((10, 20, 30)), "image/png")),
                                ("files", ("b.png", pic((40, 50, 60)), "image/png"))])
        assert r.status_code == 201
        a, b = r.json()
        assert a["looking"] and a["note"] == "海边的傍晚" and a["source"] == "mine" and a["batch"] == b["batch"]
        again = await c.post("/album", files=[("files", ("a.png", pic((10, 20, 30)), "image/png"))])
        assert again.json() == []                                               # 同一张加过的跳过

        e.model.script = [{"calls": [("album_write", {"id": a["id"], "caption": "她踩着浪", "felt": "想笑",
                                                      "why": "第一次看海", "thoughts": "光是橘色的。"}),
                                     ("album_write", {"id": b["id"], "caption": "沙滩上的脚印"})]}, ""]
        await tick_once(e.deps, e.rooms)
        assert e.model.requests == []                                           # 还没到一分钟
        clock["now"] = NOW + timedelta(minutes=2)
        await tick_once(e.deps, e.rooms)
        req = e.model.requests[0]
        assert [x.name for x in req.tools] == ["album_write"]
        assert "〔相册〕" in req.messages[-1].text and "海边的傍晚" in req.messages[-1].text
        assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE role = 'assistant'") == 0   # 不进聊天

        got = {p["id"]: p for p in (await c.get("/album")).json()}
        assert got[a["id"]]["caption"] == "她踩着浪" and got[a["id"]]["thoughts"] == "光是橘色的。"
        assert not got[a["id"]]["looking"] and not got[b["id"]]["looking"]

        assert (await c.patch(f"/album/{a['id']}", json={"starred": True})).json()["starred"]
        assert [p["id"] for p in (await c.get("/album", params={"book": "starred"})).json()] == [a["id"]]
        await c.patch(f"/album/{b['id']}", json={"secret": True})
        assert [p["id"] for p in (await c.get("/album")).json()] == [a["id"]]   # 隐私的默认不给
        assert [p["id"] for p in (await c.get("/album", params={"book": "secret"})).json()] == [b["id"]]
        assert (await c.get("/album", params={"book": "nope"})).status_code == 400

        img = await c.get(f"/album/{a['id']}/image")
        assert img.status_code == 200 and img.headers["content-type"] == "image/jpeg"
        small = await c.get(f"/album/{b['id']}/image", params={"thumb": 1})
        assert small.status_code == 200 and Path(await pool.fetchval("SELECT path FROM album_photos WHERE id = $1", b["id"])
                                                 ).with_suffix(".thumb.jpg").exists()
        export = (await c.get("/me/export")).json()
        assert {p["caption"] for p in export["album"]} == {"她踩着浪", "沙滩上的脚印"}
        path = await pool.fetchval("SELECT path FROM album_photos WHERE id = $1", b["id"])
        assert (await c.delete(f"/album/{b['id']}")).status_code == 204 and not Path(path).exists()
        assert not Path(path).with_suffix(".thumb.jpg").exists()

    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/album")).json() == []
        assert (await c.get(f"/album/{a['id']}/image")).status_code == 404
        assert (await c.patch(f"/album/{a['id']}", json={"starred": False})).status_code == 404


async def test_keep_from_chat_and_look(pool, tmp_path):
    e = Env(pool, ["一支粉色冰淇淋，背后是夕阳", {"calls": [("album", {"action": "keep", "which": 1, "caption": "她举着冰淇淋", "felt": "甜",
                                         "why": "夏天最后一支"}),
                              ("album", {"action": "keep", "which": 5, "caption": "?"})]}, "好看"])
    e.deps.keys.trial = Route("anthropic", "ours", "fake-chat", "fake-ledger", trial=True)       # 会看图的一家
    e.app.state.api.cfg.files_dir = tmp_path
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, **QUIET}})
        photo = (await c.post(f"/conversations/{conv['id']}/attachments",
                              files={"file": ("p.png", pic((9, 9, 9)), "image/png")})).json()
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "看！", "attachments": [photo["id"]]})
        await e.rooms.idle(UUID(conv["id"]))
        res = e.model.requests[2].rounds[0].results                            # 第一次是看图写描述

        assert res[0].startswith("收进相册了") and "第 5 张没有" in res[1]
        [p] = (await c.get("/album")).json()
        assert (p["source"], p["caption"], p["felt"], p["looking"]) == ("chat", "她举着冰淇淋", "甜", False)
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        assert any(card["kind"] == "photo" for m in msgs for card in m["cards"])
    acc = await pool.fetchval("SELECT account_id FROM companions")
    told = await AL.look(pool, acc, UUID(comp["id"]), None, random.Random(1))
    assert "你的图注：她举着冰淇淋" in told and "为什么留：夏天最后一支" in told
    assert "没有 #999" in await AL.look(pool, acc, UUID(comp["id"]), 999, random.Random(1))
