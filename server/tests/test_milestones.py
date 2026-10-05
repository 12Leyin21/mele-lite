"""里程碑（10-05 上服务器）：它觉得这一刻值得记住就立一座；Record 的大事记读 GET /milestones。测试用小满 / Mia。"""
from datetime import datetime, timedelta, timezone

from brain import accounts, auth, edits
from brain import milestones as MS
from brain.edits import EditRef
from brain.tools import ToolContext, run_tool, tool_note
from llm.types import ToolCall

NOW = datetime(2026, 10, 5, 8, tzinfo=timezone.utc)


async def setup(pool):
    acc = await auth.new_account(pool)
    mia = (await accounts.list_companions(pool, acc))[0]
    conv = await accounts.new_conversation(pool, acc, mia)
    msg = await pool.fetchval("INSERT INTO chat_messages (user_id, role, text) VALUES ($1, 'user', '我们第一次一起看海') "
                              "RETURNING id", conv)
    return acc, mia, conv, msg


async def test_tool_sets_milestone_with_card(pool):
    acc, mia, conv, msg = await setup(pool)
    ctx = ToolContext(pool=pool, embedder=None, user_id=mia, account_id=acc, now=NOW, edit_ref=EditRef(conv, msg))
    got = await run_tool(ctx, ToolCall("t", "milestone", {"title": "第一次一起看海"}))
    assert got.startswith("立好了") and ctx.cards[-1].kind == "date" and not ctx.cards[-1].private
    assert ctx.cards[-1].text == "立了里程碑：第一次一起看海"
    rows = await MS.list_all(pool, acc)
    assert [(r["title"], r["companion_id"]) for r in rows] == [("第一次一起看海", str(mia))]
    again = await run_tool(ctx, ToolCall("t", "milestone", {"title": "第一次一起看海"}))   # 同一天同一句不重复立
    assert again.startswith("这座已经立过") and len(await MS.list_all(pool, acc)) == 1
    assert tool_note("milestone", {"title": "第一次一起看海"}, got, "zh") == "立了里程碑「第一次一起看海」"
    await edits.undo(pool, None, conv, msg)                                                # 倒回这一轮：拿掉
    assert await MS.list_all(pool, acc) == []


async def test_tool_needs_title_and_finds_account(pool):
    acc, mia, *_ = await setup(pool)
    ctx = ToolContext(pool=pool, embedder=None, user_id=mia, now=NOW)                     # 没给账号：按联系人查
    assert (await run_tool(ctx, ToolCall("t", "milestone", {"title": "  "}))).startswith("要写")
    await run_tool(ctx, ToolCall("t", "milestone", {"title": "说好了一起去日本"}))
    assert len(await MS.list_all(pool, acc)) == 1


async def test_same_title_another_day_is_new(pool):
    acc, mia, *_ = await setup(pool)
    assert await MS.add(pool, acc, mia, "一起做饭", now=NOW) is not None
    assert await MS.add(pool, acc, mia, "一起做饭", now=NOW + timedelta(days=3)) is not None
    assert len(await MS.list_all(pool, acc)) == 2


async def test_endpoint_lists_own_milestones(pool, tmp_path):
    from tests.test_host import client, make_app
    acc, mia, *_ = await setup(pool)
    other = await auth.new_account(pool)
    await MS.add(pool, other, (await accounts.list_companions(pool, other))[0], "别人的", now=NOW)
    await MS.add(pool, acc, mia, "第一次一起看海", now=NOW)
    app = make_app(pool, host_mode=False)
    token = await auth.new_session(pool, acc, secret="test-secret", now=NOW)
    async with client(app, token) as c:
        r = await c.get("/milestones")
    assert r.status_code == 200
    assert [(m["title"], m["companion_id"]) for m in r.json()] == [("第一次一起看海", str(mia))]
    assert r.json()[0]["at"].startswith("2026-10-05")
