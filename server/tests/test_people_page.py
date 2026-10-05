"""人物卡页面 + 对谁隐藏（10-01）：增删改查、别人看不到、藏起来的卡这个联系人联想不到 / 翻不到 / 写不了。测试用小满、Ava。"""
from datetime import datetime, timezone
from uuid import UUID

from brain import accounts
from brain.scope import Scope
from brain.tools import ToolContext, run_tool
from brain.turn import run_turn
from llm.types import ToolCall
from test_api import Env


async def test_people_api_and_hiding(pool):
    e = Env(pool, ["嗯嗯", "嗯嗯"])
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        ava_comp = (await c.post("/companions", json={"name": "Ava"})).json()
        r = await c.post("/people", json={"name": "阿杰", "relation": "前任", "facts": "分手两年了", "aliases": ["杰哥"],
                                          "hidden_from": [lumi["id"]]})
        assert r.status_code == 201
        p = r.json()
        assert (p["name"], p["relation"], p["aliases"], p["created_by"], p["hidden_from"]) == \
               ("阿杰", "前任", ["杰哥"], "user", [lumi["id"]])
        assert (await c.post("/people", json={"name": "阿杰"})).status_code == 409
        assert (await c.post("/people", json={"name": " "})).status_code == 400
        p2 = (await c.patch(f"/people/{p['id']}", json={"facts": "分手三年了", "hidden_from": [lumi["id"], ava_comp["id"]]})).json()
        assert p2["facts"] == "分手三年了" and set(p2["hidden_from"]) == {lumi["id"], ava_comp["id"]}
        p3 = (await c.patch(f"/people/{p['id']}", json={"hidden_from": [ava_comp["id"]]})).json()
        assert p3["hidden_from"] == [ava_comp["id"]]
        await c.patch(f"/people/{p['id']}", json={"hidden_from": [lumi["id"]]})
        me = UUID((await c.get("/me")).json()["id"])
    async with e.client(other) as c:
        assert (await c.get("/people")).json() == []
        assert (await c.patch(f"/people/{p['id']}", json={"facts": "x"})).status_code == 404
        assert (await c.patch(f"/people/{p['id']}", json={"hidden_from": ["not-a-uuid"]})).status_code == 404

    # Lumi 看不到阿杰：说到他不递卡、工具翻不到也写不了；Ava 照样看得到
    lumi_id = UUID(lumi["id"])

    async def emit(_):
        return None
    await run_turn(e.deps, Scope(me, lumi_id, UUID(conv["id"])), "杰哥今天找我了", emit)
    assert "阿杰" not in e.model.requests[-1].messages[-1].text
    ava_conv = UUID(ava_comp["conversation"])
    await run_turn(e.deps, Scope(me, UUID(ava_comp["id"]), ava_conv), "杰哥今天找我了", emit)
    assert "〔人物卡 · 阿杰" in e.model.requests[-1].messages[-1].text
    ctx = ToolContext(pool=pool, embedder=e.deps.embedder, user_id=lumi_id, account_id=me, now=datetime.now(timezone.utc))
    assert await run_tool(ctx, ToolCall("1", "person_card", {"action": "get", "name": "阿杰"})) == "没有这张卡。"
    assert await run_tool(ctx, ToolCall("2", "person_card", {"action": "write", "name": "杰哥", "impression": "x"})) \
        == "这个人的卡你写不了。"

    async with e.client(t) as c:
        assert (await c.delete(f"/people/{p['id']}")).status_code == 204
        assert (await c.get("/people")).json() == []
        assert (await c.delete(f"/people/{p['id']}")).status_code == 404
