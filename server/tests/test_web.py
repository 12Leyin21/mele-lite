import json

import httpx

from brain import archive
from brain.turn import Deps
from llm.fake import FakeModel
from llm.router import Route
from llm.types import Usage
from memory.embed import FakeEmbedder
from web.app import create_app


class OneKey:
    def route_for(self, user_id):
        return Route("fake", "k", "fake-chat", "fake-ledger")


def client(pool, user, model):
    async def nosleep(_):
        return None
    deps = Deps(pool=pool, embedder=FakeEmbedder(), keys=OneKey(), adapter_for=lambda r: model, sleep=nosleep)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=create_app(deps, user)), base_url="http://test")


def events(text):
    return [json.loads(line[6:]) for line in text.splitlines() if line.startswith("data: ")]


async def test_index_is_served(pool, user_a):
    async with client(pool, user_a, FakeModel([])) as c:
        r = await c.get("/")
    assert r.status_code == 200 and "<html" in r.text


async def test_chat_streams_events(pool, user_a):
    async with client(pool, user_a, FakeModel(["你好\n\n我在"])) as c:
        r = await c.post("/api/chat", json={"text": "在吗"})
    ev = events(r.text)
    assert r.headers["content-type"].startswith("text/event-stream")
    assert [e["text"] for e in ev if e["type"] == "bubble"] == ["你好", "我在"] and ev[-1]["type"] == "done"


async def test_empty_chat_rejected(pool, user_a):
    async with client(pool, user_a, FakeModel([])) as c:
        assert (await c.post("/api/chat", json={"text": "  "})).status_code == 400


async def test_crash_becomes_an_error_event(pool, user_a):
    async with client(pool, user_a, FakeModel([])) as c:        # 剧本是空的：模型一调就炸
        ev = events((await c.post("/api/chat", json={"text": "在吗"})).text)
    assert ev[-2]["type"] == "error" and ev[-2]["kind"] == "server" and ev[-1]["type"] == "done"


async def test_settings_validated_and_saved(pool, user_a):
    async with client(pool, user_a, FakeModel([])) as c:
        assert (await c.put("/api/settings", json={"lang": "en", "max_bubbles": 3})).status_code == 200
        assert (await c.put("/api/settings", json={"lang": "fr"})).status_code == 400
        s = (await c.get("/api/state")).json()
    assert s["settings"]["lang"] == "en" and s["settings"]["max_bubbles"] == 3


async def test_persona_saved_and_state_shape(pool, user_a):
    await archive.add_message(pool, user_a, "user", "早")
    async with client(pool, user_a, FakeModel([])) as c:
        r = (await c.put("/api/persona", json={"name": "阿澄", "imported": "你是一只猫"})).json()
        s = (await c.get("/api/state")).json()
    assert r["persona"]["name"] == "阿澄" and r["import_cost_usd"] is None      # fake-chat 不在清单里
    assert set(s) == {"settings", "persona", "model", "ledger", "sticky", "usage_today", "history", "where"}
    assert s["persona"]["imported"] == "你是一只猫" and s["history"][0]["text"] == "早"
    assert s["model"] == {"provider": "fake", "chat": "fake-chat", "ledger": "fake-ledger", "age": "fake-ledger"}


async def test_cache_check_endpoint(pool, user_a):
    model = FakeModel([{"text": "好", "usage": Usage(input=2000)}, {"text": "好", "usage": Usage(input=5, cache_read=1995)}])
    async with client(pool, user_a, model) as c:
        r = (await c.post("/api/cache-check")).json()
    assert r["result"] == "hit" and model.requests[0].system[0].text.startswith("你是一个住在手机 app 里的 AI 伙伴")


async def test_memories_page_and_api_show_everything_and_delete(pool, user_a):
    import memory as M
    e = FakeEmbedder()
    m = (await M.remember(pool, e, user_a, "下周二考 OSCE")).memory
    a = (await M.remember(pool, e, user_a, "燕麦拿铁要半糖", kind="about")).memory
    await M.upsert_person(pool, e, user_a, "阿杰", relation="室友")
    await M.set_sticky(pool, user_a, "明早问面试")
    async with client(pool, user_a, FakeModel([])) as c:
        assert "<html" in (await c.get("/memories")).text
        d = (await c.get("/api/memories")).json()
        assert {x["kind"] for x in d["memories"]} == {"memory", "about"}       # 调试页里「关于 TA」也看得到
        assert d["people"][0]["name"] == "阿杰" and d["sticky"] == "明早问面试" and d["ledger"] == []
        assert (await c.delete(f"/api/memories/{m.id}")).json() == {"deleted": True}
        assert (await c.delete(f"/api/memories/{m.id}")).json() == {"deleted": False}
        assert [x["id"] for x in (await c.get("/api/memories")).json()["memories"]] == [a.id]


async def test_contacts_windows_incognito_rewind_through_the_page(pool):
    from brain import accounts
    from brain.scope import Scope
    acc = await accounts.create_account(pool)
    lumi = await accounts.create_companion(pool, acc)
    w1 = await accounts.new_conversation(pool, acc, lumi)
    m = FakeModel(["在的", "嗯嗯", "你好，初次见面", "好的"])
    async with client(pool, Scope(acc, lumi, w1), m) as c:
        await c.post("/api/chat", json={"text": "在吗"})
        await c.post("/api/chat", json={"text": "今天好累"})
        hist = (await c.get("/api/state")).json()["history"]
        assert [h["text"] for h in hist] == ["在吗", "在的", "今天好累", "嗯嗯"] and not hist[0]["rolled"]
        assert (await c.post("/api/rewind", json={"message_id": hist[2]["id"]})).json() == {"kind": "edit", "text": "今天好累"}
        assert [h["text"] for h in (await c.get("/api/state")).json()["history"]] == ["在吗", "在的"]
        m.script.insert(0, "换个说法：在呢")
        assert (await c.post("/api/rewind", json={"message_id": hist[1]["id"]})).json() == {"kind": "regenerate"}
        await c.post("/api/chat", json={"resend": True})
        assert [h["text"] for h in (await c.get("/api/state")).json()["history"]] == ["在吗", "换个说法：在呢"]

        on = (await c.post("/api/incognito", json={"on": True})).json()
        assert on["incognito"] and on["conversation"] != str(w1)
        assert (await c.post("/api/conversations")).status_code == 400                  # 无痕里不能开新窗口
        await c.post("/api/chat", json={"text": "你好"})
        off = (await c.post("/api/incognito", json={"on": False})).json()
        assert not off["incognito"] and off["conversation"] == str(w1)
        assert [h["text"] for h in (await c.get("/api/state")).json()["history"]] == ["在吗", "换个说法：在呢"]

        w = (await c.post("/api/companions", json={"name": "阿澄"})).json()
        assert [x["name"] for x in w["companions"]] == ["Lumi", "阿澄"] and w["companion"] != str(lumi)
        assert (await c.get("/api/state")).json()["history"] == []                       # 新联系人，新窗口
        back = (await c.post("/api/switch", json={"companion": str(lumi)})).json()
        assert back["conversation"] == str(w1)
        nw = (await c.post("/api/conversations")).json()
        assert nw["conversation"] != str(w1) and len(nw["conversations"]) == 2
