"""搬别的 AI 的官方聊天记录上 Host（10-05）：新窗口按原时间、每段一行灰字、只有最后 40 条进上下文；
后台挑记忆进记忆库（编的不要）、官方笔记原样存、模型没回下次接着挑。测试用小满 / Mia。"""
import asyncio
from datetime import datetime, timedelta, timezone
from uuid import UUID

import memory as M
from brain import chat_import as CI
from llm.errors import LLMError
from test_api import Env

T0 = datetime(2025, 9, 20, 6, 0, tzinfo=timezone.utc)


def body(n=3, **over):
    msgs = [{"role": "user" if i % 2 == 0 else "assistant", "text": f"第{i}句", "at": (T0 + timedelta(minutes=i)).isoformat()}
            for i in range(n)]
    msgs[0]["text"] = "我养了一只橘猫叫年糕"
    b = {"source": "deepseek", "conversations": [
        {"title": "猫", "messages": msgs},
        {"title": "", "messages": [{"role": "user", "text": "早", "at": "2025-09-19T00:00:00Z"},
                                   {"role": "system", "text": "不要", "at": "2025-09-19T00:00:01Z"}]},
    ], "extra": ["小满喜欢芒果"], "memories": True}
    b.update(over)
    return b


async def _wait(cid):
    for _ in range(200):
        if UUID(cid) not in CI._running:
            return
        await asyncio.sleep(0.01)


async def _setup(pool, script):
    e = Env(pool, script)
    t = await e.login()
    return e, t


async def test_new_window_keeps_time_dividers_and_only_last_40_live(pool):
    e, t = await _setup(pool, [])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        r = await c.post(f"/companions/{comp['id']}/import", json=body(n=50, memories=False))
        assert r.status_code == 201 and r.json()["messages"] == 51 and r.json()["picking"] is False
        vid = UUID(r.json()["conversation_id"])
        assert await pool.fetchval("SELECT title FROM conversations WHERE id = $1", vid) == "从 DeepSeek 搬来的"
        assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE user_id = $1 AND NOT rolled", vid) == 40
        msgs = (await c.get(f"/conversations/{vid}/messages?limit=500")).json()["messages"]
        assert msgs[0]["text"] == "早" and msgs[0]["divider"] == "DeepSeek ·《没有标题》· 2025-09-19"   # 早的那段在前；系统消息不要
        assert msgs[1]["divider"].startswith("DeepSeek ·《猫》") and msgs[2]["divider"] is None
        assert msgs[1]["cards"] == [] and msgs[1]["at"].startswith("2025-09-20T06:00")
        assert (await c.get(f"/companions/{comp['id']}/import")).json() == {"state": "idle"}


async def test_picks_grounded_memories_and_keeps_official_notes(pool):
    e, t = await _setup(pool, ["（没有）", "- 2025-09-20｜小满养了一只橘猫叫年糕\n- 2025-09-20｜小满下个月要去东京旅行"])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.put("/me/profile", json={"name": "小满"})
        r = await c.post(f"/companions/{comp['id']}/import", json=body())
        await _wait(comp["id"])
        got = (await c.get(f"/companions/{comp['id']}/import")).json()
    assert got == {"state": "done", "done": 2, "total": 2, "picked": 1, "to": "memory", "error": ""}
    texts = sorted(m.content for m in await M.list_memories(pool, UUID(comp["id"])))
    assert texts == ["小满喜欢芒果", "（2025-09-20）小满养了一只橘猫叫年糕"]     # 东京是编的
    first, second = (r.messages[-1].text for r in e.model.requests)       # 每段对话各切成块：早的那段先挑
    assert "〔2025-09-19〕" in first and "小满：早" in first and "不用「他」「她」" in first
    assert "小满：我养了一只橘猫叫年糕" in second
    assert r.json()["picking"] is True


async def test_model_error_stops_and_next_look_resumes(pool):
    e, t = await _setup(pool, [LLMError("overloaded", "x")])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.post(f"/companions/{comp['id']}/import", json=body())
        await _wait(comp["id"])
        assert (await c.get(f"/companions/{comp['id']}/import")).json()["state"] == "failed"
        e.model.script = ["（没有）", "（没有）"]
        state = await CI.archive.get_state(pool, UUID(comp["id"]))
        state["import_job"]["state"] = "picking"                  # App 那边「接着挑」= 再看一眼
        await CI.archive.save_state(pool, UUID(comp["id"]), state)
        await c.get(f"/companions/{comp['id']}/import")
        await _wait(comp["id"])
        got = (await c.get(f"/companions/{comp['id']}/import")).json()
    assert got["state"] == "done" and got["picked"] == 0
    assert len(await M.list_memories(pool, UUID(comp["id"]))) == 1       # 官方笔记只存了一次


async def test_bad_bodies_are_400(pool):
    e, t = await _setup(pool, [])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        assert (await c.post(f"/companions/{comp['id']}/import", json=body(source="bing"))).status_code == 400
        assert (await c.post(f"/companions/{comp['id']}/import", json=body(conversations=[]))).status_code == 400
        assert (await c.post("/companions/6b1f0c3e-1111-4a2b-9c3d-000000000009/import", json=body())).status_code == 404


async def test_gemini_divider_is_just_the_day(pool):
    e, t = await _setup(pool, [])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        r = await c.post(f"/companions/{comp['id']}/import", json=body(source="gemini", memories=False))
        msgs = (await c.get(f"/conversations/{r.json()['conversation_id']}/messages")).json()["messages"]
    assert msgs[0]["divider"] == "Gemini · 2025-09-19"


def test_parse_and_chunks():
    assert CI.parse_picked("- 2025-09-20｜猫\n- 2025-09-21 | 雪\n- 没日期\n废话\n- （没有）") == \
        [("2025-09-20", "猫"), ("2025-09-21", "雪"), ("", "没日期")]
    msgs = [{"role": "user" if i % 2 == 0 else "assistant", "text": "字" * 300, "at": T0 + timedelta(minutes=i)} for i in range(30)]
    parts = CI.chunks([{"title": "", "messages": msgs}], "小满", "UTC", size=2000)
    assert len(parts) > 1 and all(len(p) <= 2400 for p in parts) and parts[0].startswith("〔2025-09-20〕")
    assert "小满：" in parts[0] and "我：" in parts[0]
