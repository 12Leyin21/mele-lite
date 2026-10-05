"""世界书（09-30）：存取、校验、可见性、匹配、按轮冷却、常驻。测试用小满 / Mia。"""
import pytest

from brain import accounts
from brain import lore as L


async def setup(pool):
    acc = await accounts.create_account(pool)
    a = await accounts.create_companion(pool, acc)
    b = await accounts.create_companion(pool, acc)
    return acc, a, b


async def test_add_validates(pool):
    acc, a, _ = await setup(pool)
    e = await L.add(pool, acc, companion_id=a, name="日久方长", keywords="日久方长，日久", content="我们自己的词", created_by="user")
    assert e.keywords == ["日久方长", "日久"] and e.enabled and not e.constant
    assert (await L.add(pool, acc, companion_id=a, name="猫", keywords="猫", content="一个汉字也行", created_by="user")).keywords == ["猫"]
    for bad in ({"keywords": "a"}, {"keywords": ""}, {"content": ""}, {"content": "字" * 2001}, {"name": ""},
                {"keywords": [f"词{i}" for i in range(11)]}, {"created_by": "mia"}):
        kw = {"companion_id": a, "name": "x", "keywords": "关键", "content": "内容", "created_by": "user", **bad}
        with pytest.raises(ValueError):
            await L.add(pool, acc, **kw)


async def test_limit(pool, monkeypatch):
    acc, a, _ = await setup(pool)
    monkeypatch.setattr(L, "MAX_ENTRIES", 2)
    for i in range(2):
        await L.add(pool, acc, companion_id=a, name=f"梗{i}", keywords=f"梗梗{i}", content="c", created_by="user")
    with pytest.raises(ValueError):
        await L.add(pool, acc, companion_id=a, name="多", keywords="多了", content="c", created_by="user")


async def test_visibility_private_and_shared(pool):
    acc, a, b = await setup(pool)
    other = await accounts.create_account(pool)
    mine = await L.add(pool, acc, companion_id=a, name="日久方长", keywords="日久方长", content="密语", created_by="ai")
    shared = await L.add(pool, acc, companion_id=None, name="city walk", keywords="city walk", content="梗", created_by="user")
    assert [e.id for e in await L.list_for(pool, acc, a)] == [mine.id, shared.id]
    assert [e.id for e in await L.list_for(pool, acc, b)] == [shared.id]          # Ava 不知道 Lumi 的密语
    assert len(await L.list_for(pool, acc)) == 2
    assert await L.get(pool, other, mine.id) is None and not await L.delete(pool, other, mine.id)
    assert (await L.get_by_name(pool, acc, a, " 日久方长 ")).id == mine.id
    moved = await L.update(pool, acc, mine.id, companion_id=None, content="大家都知道了")
    assert moved.companion_id is None and moved.content == "大家都知道了" and moved.name == "日久方长"
    assert await L.delete(pool, acc, mine.id) and await L.get(pool, acc, mine.id) is None


def entry(i, name, kws, content="c", **kw):
    return L.Entry(i, None, None, name, kws, content, "user", kw.get("enabled", True), kw.get("constant", False))


def test_hits_ignore_width_and_case_and_prefer_longer():
    es = [entry(1, "日久", ["日久"]), entry(2, "日久方长", ["日久方长"]), entry(3, "CW", ["City Walk"]),
          entry(4, "关着的", ["方长"], enabled=False), entry(5, "常驻", ["日久"], constant=True)]
    got = L.hits(es, ["今天也是ｃｉｔｙ　ｗａｌｋ", "日久方长呀"])
    assert [(e.id, n) for e, n in got] == [(3, 9), (2, 4), (1, 2)]
    assert L.hits(es, ["没提到"]) == []


def test_pick_cooldown_by_turns_and_char_budget():
    es = [entry(1, "日久方长", ["日久方长"], "我们的词"), entry(2, "长的", ["长长的设定"], "字" * 1990)]
    st = {}
    first = L.pick(es, ["日久方长", "长长的设定"], st, 5, "zh")
    assert first.startswith("〔世界书〕\n【长的】")                        # 关键词长的先
    assert "【日久方长】" not in first and "本来就知道" in first          # 放不下的这轮不递
    second = L.pick(es, ["日久方长", "长长的设定"], st, 6, "zh")
    assert "【日久方长】我们的词" in second and "【长的】" not in second    # 长的在冷却里
    assert L.pick(es, ["日久方长"], st, 25, "zh") == ""                    # 第 6 轮递过，第 25 轮还差一轮
    assert "【日久方长】" in L.pick(es, ["日久方长"], st, 26, "zh")
    assert L.pick(es, ["日久方长"], {}, 1, "en").startswith("〔Lore〕")


def test_always_block():
    es = [entry(1, "世界", ["世界观"], "赛博江湖", constant=True), entry(2, "梗", ["梗梗"]),
          entry(3, "关了", ["关关"], constant=True, enabled=False)]
    assert L.always_block(es, "zh") == "〔世界书 · 一直记着的〕\n【世界】赛博江湖"
    assert L.always_block([es[1]], "zh") == ""


async def test_turn_gets_lore_once_and_always_in_base(pool):
    from uuid import UUID

    from brain.scope import Scope
    from brain.turn import run_turn
    from test_api import Env

    e = Env(pool, ["嗯嗯", "好呀", "哈哈", "嘿", "在"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        me = UUID((await c.get("/me")).json()["id"])
        inc = (await c.post(f"/companions/{comp['id']}/conversations", json={"incognito": True})).json()
    cid = UUID(comp["id"])
    await L.add(pool, me, companion_id=cid, name="日久方长", keywords="日久方长", content="我们自己的词，意思是来日方长", created_by="user")
    await L.add(pool, me, companion_id=cid, name="世界", keywords="世界观", content="赛博江湖", created_by="user", constant=True)

    async def emit(_):
        return None
    scope = Scope(me, cid, UUID(conv["id"]))
    await run_turn(e.deps, scope, "日久方长呀", emit)
    first = e.model.requests[0]
    assert "〔世界书〕\n【日久方长】我们自己的词" in first.messages[-1].text
    assert "【世界】赛博江湖" in first.system[0].text and "【世界】" not in first.messages[-1].text
    await run_turn(e.deps, scope, "嗯", emit)                  # 上一句还提着，但刚递过：不再给
    assert "〔世界书〕" not in e.model.requests[1].messages[-1].text
    await run_turn(e.deps, Scope(me, cid, UUID(inc["id"]), incognito=True), "日久方长", emit)
    assert "〔世界书〕" not in e.model.requests[2].messages[-1].text and "赛博江湖" not in e.model.requests[2].system[0].text


# ---- 第 3 步：工具 lore + 倒回 -----------------------------------------------------------------------

async def test_tool_write_get_and_cannot_touch_user_entries(pool):
    from datetime import datetime, timezone

    from brain import edits
    from brain.edits import EditRef
    from brain.tools import INCOGNITO_TOOLS, ToolContext, run_tool, tool_note
    from llm.types import ToolCall

    acc, a, b = await setup(pool)
    conv = await accounts.new_conversation(pool, acc, a)
    msg = await pool.fetchval("INSERT INTO chat_messages (user_id, role, text) VALUES ($1, 'user', '教你个词') RETURNING id", conv)
    ctx = ToolContext(pool=pool, embedder=None, user_id=a, account_id=acc, now=datetime.now(timezone.utc),
                      edit_ref=EditRef(conv, msg))

    async def call(**args):
        return await run_tool(ctx, ToolCall("t", "lore", args))

    got = await call(action="write", name="日久方长", keywords=["日久方长"], content="Mia 和 Lumi 自己的词")
    assert got.startswith("记好了：【日久方长】") and ctx.cards[-1].text == "记进世界书：日久方长" and not ctx.cards[-1].private
    e = await L.get_by_name(pool, acc, a, "日久方长")
    assert (e.created_by, e.companion_id) == ("ai", a)
    assert await L.get_by_name(pool, acc, b, "日久方长") is None                  # 只有 Lumi 知道
    await call(action="write", name="日久方长", content="改一改")                  # 同名 = 改，关键词不写就不动
    e = await L.get(pool, acc, e.id)
    assert (e.content, e.keywords) == ("改一改", ["日久方长"])
    assert "【日久方长】" in await call(action="get", name="日久方长")
    await L.add(pool, acc, companion_id=None, name="city walk", keywords="city walk", content="TA 写的", created_by="user")
    res = await call(action="write", name="City Walk", content="我来改")
    assert res.startswith("这条是 TA 写的") and tool_note("lore", {"action": "write", "name": "City Walk"}, res, "zh").endswith("✗")
    assert (await call(action="write", name="x", content="x")).startswith("工具出错")           # 关键词太短（一个字母）
    await call(action="write", name="赛博江湖", keywords=["赛博江湖"], content="设定", shared=True)
    assert (await L.get_by_name(pool, acc, b, "赛博江湖")).companion_id is None
    assert "lore" not in INCOGNITO_TOOLS

    # 倒回这一轮：新记的删掉，改过的改回去
    await edits.undo(pool, None, conv, msg)
    assert await L.get_by_name(pool, acc, a, "日久方长") is None and await L.get_by_name(pool, acc, a, "赛博江湖") is None
    assert (await L.get_by_name(pool, acc, a, "city walk")).content == "TA 写的"


# ---- 第 4 步：接口 + 导出 --------------------------------------------------------------------------

async def test_api_crud_isolated_and_exported(pool):
    from uuid import UUID

    from brain import accounts as A
    from test_api import Env

    e = Env(pool)
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        r = await c.post("/lore", json={"name": "日久方长", "keywords": "日久方长, 日久", "content": "我们的词",
                                        "companion_id": comp["id"]})
        assert r.status_code == 201 and r.json()["created_by"] == "user" and r.json()["keywords"] == ["日久方长", "日久"]
        lid = r.json()["id"]
        assert (await c.post("/lore", json={"name": "x", "keywords": "a", "content": "c"})).status_code == 400
        shared = (await c.post("/lore", json={"name": "city walk", "keywords": ["city walk"], "content": "梗"})).json()
        assert shared["companion_id"] is None
        assert [x["name"] for x in (await c.get("/lore")).json()] == ["日久方长", "city walk"]
        assert len((await c.get("/lore", params={"companion_id": comp["id"]})).json()) == 2
        p = (await c.patch(f"/lore/{lid}", json={"enabled": False, "companion_id": None})).json()
        assert p["enabled"] is False and p["companion_id"] is None and p["content"] == "我们的词"
        assert (await c.patch("/lore/99999", json={"enabled": True})).status_code == 404
        me = UUID((await c.get("/me")).json()["id"])
    assert [x["name"] for x in (await A.export_account(pool, me))["lore"]] == ["日久方长", "city walk"]
    async with e.client(other) as c:
        assert (await c.get("/lore")).json() == []
        assert (await c.patch(f"/lore/{lid}", json={"content": "偷改"})).status_code == 404
        assert (await c.delete(f"/lore/{lid}")).status_code == 404
        assert (await c.post("/lore", json={"name": "a", "keywords": "ab", "content": "c",
                                            "companion_id": comp["id"]})).status_code == 404     # 别人的联系人
    async with e.client(t) as c:
        assert (await c.delete(f"/lore/{lid}")).status_code == 204
