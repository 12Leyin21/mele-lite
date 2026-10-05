"""塔罗解牌那一小轮（10-03）：联系人带人设 + 记忆、解牌人什么都不带、只给 tarot_write、不进聊天、
出错退回等巡逻、三次不成 failed、追问接着原局。测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import UUID

import memory as M
from brain import tarot as T
from brain import tarot_read as TR
from llm.errors import LLMError
from test_api import Env

NOW = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)


async def _setup(pool, script):
    e = Env(pool, script)
    clock = {"now": NOW}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
    cid = UUID(comp["id"])
    acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", cid)
    return e, clock, acc, cid


async def _reading(pool, acc, comp, reader, spread="three", q="小满这周的面试会顺吗"):
    did, _ = await T.new_deck(pool, acc, "", NOW)
    n = {"three": 3, "single": 1}[spread]
    return await T.save(pool, acc, deck_id=did, spread=spread, question=q, reader=reader, route_from=comp,
                        picks=list(range(n)), mode="hand", now=NOW)


async def test_contact_reads_with_persona_and_memory(pool):
    e, _, acc, comp = await _setup(pool, [{"calls": [("tarot_write", {"text": "过去那张说你准备得很足。"})]}, ""])
    await M.remember(pool, e.deps.embedder, comp, "小满下周三有个面试，很紧张")
    r = await _reading(pool, acc, comp, comp)
    await TR.read_now(e.deps, acc, r.id)
    req = e.model.requests[0]
    assert [t.name for t in req.tools] == ["tarot_write"]
    ask = req.messages[-1].text
    assert "〔塔罗〕" in ask and "小满这周的面试会顺吗" in ask and "过去｜" in ask and "关键词：" in ask
    assert "手册 · tarot" in ask and "面试" in ask
    got = await T.get(pool, acc, r.id)
    assert got.status == "done" and got.interpretation == "过去那张说你准备得很足。" and got.told is False
    assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE role = 'assistant'") == 0      # 不进聊天


async def test_neutral_reader_gets_nothing_personal(pool):
    e, _, acc, comp = await _setup(pool, ["平实地说：这张牌是指引。"])          # 不调工具直接写在回话里也收
    await M.remember(pool, e.deps.embedder, comp, "小满最喜欢芒果")
    r = await _reading(pool, acc, comp, None, spread="single", q="芒果季我该不该换工作")
    await TR.read_now(e.deps, acc, r.id)
    req = e.model.requests[0]
    sys = "".join(b.text for b in req.system)
    assert "解牌人" in sys and "最喜欢芒果" not in sys + req.messages[-1].text
    assert len(req.messages) == 1
    got = await T.get(pool, acc, r.id)
    assert got.status == "done" and got.interpretation.startswith("平实地说") and got.told is True


async def test_errors_fall_back_to_patrol_then_fail(pool):
    e, clock, acc, comp = await _setup(pool, [])
    e.model.script = [LLMError("overloaded", "x")] * 5
    r = await _reading(pool, acc, comp, comp)
    await TR.read_now(e.deps, acc, r.id)
    assert (await T.get(pool, acc, r.id)).status == "pending"
    assert await TR.run_due(e.deps, NOW + timedelta(seconds=30)) == 0            # 还没卡够两分钟
    for i in range(2):
        clock["now"] = NOW + timedelta(minutes=3 + i)
        await TR.run_due(e.deps, clock["now"])
    got = await T.get(pool, acc, r.id)
    assert got.status == "failed" and got.tries == 3
    assert (await T.retry(pool, acc, r.id))[0].status == "pending"


async def test_followup_sees_the_earlier_reading(pool):
    e, _, acc, comp = await _setup(pool, [{"calls": [("tarot_write", {"text": "三张一起看，是往上走。"})]}, "",
                                          {"calls": [("tarot_write", {"text": "这一张说别急。"})]}, ""])
    r = await _reading(pool, acc, comp, comp)
    await TR.read_now(e.deps, acc, r.id)
    did, _ = await T.new_deck(pool, acc, "", NOW)
    _, i = await T.add_followup(pool, acc, r.id, deck_id=did, pick=4, question="那要提前准备什么", mode="hand", now=NOW)
    await TR.read_now(e.deps, acc, r.id, followup=i)
    ask = e.model.requests[-1].messages[-1].text
    assert "三张一起看，是往上走。" in ask and "那要提前准备什么" in ask and "追问｜" in ask
    got = await T.get(pool, acc, r.id)
    assert got.followups[0]["interpretation"] == "这一张说别急。" and got.followups[0]["status"] == "done"
