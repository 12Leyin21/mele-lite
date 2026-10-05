"""Host 上接用户自己的 MCP 服务（10-05）：增删改查、钥匙只进不出、测一下列出工具、TA 聊天时真的调到、
无痕不给、连不上不挡聊天、删服务连 TA 的勾一起清。假服务一半回 JSON 一半回 SSE。测试用小满 / Mia。"""
import json
from uuid import UUID

import httpx
import pytest

from brain import mcp
from test_api import Env

TOKEN = "mcp-secret-123"


def fake_server(sse=False, calls=None):
    """一个最小的 MCP 服务：要钥匙；initialize 发会话号；一个工具 get_weather"""
    def reply(rid, result, headers=None):
        msg = {"jsonrpc": "2.0", "id": rid, "result": result}
        if sse:
            return httpx.Response(200, text=f"event: message\ndata: {json.dumps(msg)}\n\n",
                                  headers={"content-type": "text/event-stream", **(headers or {})})
        return httpx.Response(200, json=msg, headers=headers or {})

    def handle(req: httpx.Request):
        if req.headers.get("authorization") != f"Bearer {TOKEN}":
            return httpx.Response(401)
        body = json.loads(req.content)
        m = body.get("method")
        if m == "initialize":
            return reply(body["id"], {"protocolVersion": mcp.PROTOCOL, "capabilities": {"tools": {}}}, {"mcp-session-id": "s1"})
        assert req.headers.get("mcp-session-id") == "s1"
        if m == "notifications/initialized":
            return httpx.Response(202)
        if m == "tools/list":
            return reply(body["id"], {"tools": [{"name": "get_weather", "description": "查天气",
                                                 "inputSchema": {"type": "object", "properties": {"city": {"type": "string"}}}}]})
        if m == "tools/call":
            if calls is not None:
                calls.append(body["params"])
            return reply(body["id"], {"content": [{"type": "text", "text": "新加坡 晴 22 度"}]})
        return httpx.Response(400)
    return httpx.MockTransport(handle)


@pytest.fixture(autouse=True)
def _reset():
    yield
    mcp.TRANSPORT = None
    for d in (mcp._clients, mcp._tools, mcp._health):
        d.clear()


async def _host(pool, script):
    e = Env(pool, script)
    t = await e.login()                          # Host 没有邮箱登录：先登进去再切成 Host
    e.app.state.api.cfg.host_mode = True
    return e, t


async def test_add_list_test_patch_delete(pool):
    mcp.TRANSPORT = fake_server(sse=True)
    e, t = await _host(pool, [])
    async with e.client(t) as c:
        lumi, _ = await e.first_window(c)
        assert (await c.post("/mcp/servers", json={"name": "天气", "url": "ftp://x"})).status_code == 400
        r = await c.post("/mcp/servers", json={"name": "Weather Box", "url": "https://mcp.example.com/mcp", "token": TOKEN})
        assert r.status_code == 201 and r.json()["slug"] == "weather_box"
        sid = r.json()["id"]
        listed = (await c.get("/mcp/servers")).json()
        assert listed[0]["has_key"] is True and TOKEN not in json.dumps(listed)              # 钥匙只进不出
        got = (await c.post(f"/mcp/servers/{sid}/test")).json()
        assert got == {"ok": True, "tools": ["get_weather"], "memory": False}
        assert (await c.patch(f"/mcp/servers/{sid}", json={"token": "wrong"})).status_code == 200
        assert (await c.post(f"/mcp/servers/{sid}/test")).json() == {"ok": False, "detail": "钥匙不对"}
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"mcp_servers": [sid]}})
        assert (await c.delete(f"/mcp/servers/{sid}")).json() == {"ok": True}
        s = (await c.get(f"/companions/{lumi['id']}")).json()["settings"]
        assert s["mcp_servers"] == [] and (await c.get("/mcp/servers")).json() == []


async def test_not_on_the_official_server(pool):
    e = Env(pool, [])
    t = await e.login()
    async with e.client(t) as c:
        assert (await c.get("/mcp/servers")).status_code == 404


async def test_companion_calls_the_tool_in_chat(pool):
    calls = []
    mcp.TRANSPORT = fake_server(calls=calls)
    e, t = await _host(pool, [{"calls": [("weather_get_weather", {"city": "新加坡"})]}, "新加坡今天晴，22 度。"])
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        sid = (await c.post("/mcp/servers", json={"name": "Weather", "url": "https://mcp.example.com/mcp", "token": TOKEN})).json()["id"]
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0, "mcp_servers": [sid]}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "今天天气怎么样"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
    first = e.model.requests[0]
    tool = next(x for x in first.tools if x.name == "weather_get_weather")
    assert tool.description.startswith("（来自 Weather）") and tool.params["properties"]["city"]["type"] == "string"
    assert calls == [{"name": "get_weather", "arguments": {"city": "新加坡"}}]
    assert "新加坡 晴 22 度" in json.dumps([r.results for r in e.model.requests[1].rounds], ensure_ascii=False)
    assert msgs[-1]["text"] == "新加坡今天晴，22 度。" and {"kind": "tool", "text": "用了 Weather：get_weather"} in msgs[-1]["cards"]


async def test_offline_server_does_not_block_chat_and_incognito_gets_none(pool):
    mcp.TRANSPORT = httpx.MockTransport(lambda req: httpx.Response(503))
    e, t = await _host(pool, ["好的", "悄悄的"])
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        sid = (await c.post("/mcp/servers", json={"name": "Weather", "url": "https://mcp.example.com/mcp"})).json()["id"]
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0, "mcp_servers": [sid]}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "在吗"})
        await e.rooms.idle(UUID(conv["id"]))
        assert not any(x.name.startswith("weather_") for x in e.model.requests[0].tools)
        assert (await c.get("/mcp/servers")).json()[0]["status"] == "offline"
        mcp.TRANSPORT = fake_server()
        mcp._tools.clear()
        inc = (await c.post(f"/companions/{lumi['id']}/conversations", json={"incognito": True})).json()
        await c.post(f"/conversations/{inc['id']}/messages", json={"text": "嘘"})
        await e.rooms.idle(UUID(inc["id"]))
        assert not any(x.name.startswith("weather_") for x in e.model.requests[-1].tools)


def test_names():
    assert mcp.slug("我的 Memory Box!", 3) == "memory_box" and mcp.slug("记忆库", 2) == "mcp2"
    assert mcp.exposed("notion", "search.pages") == "notion_search_pages"
    assert len(mcp.exposed("a" * 20, "b" * 80)) == 64
