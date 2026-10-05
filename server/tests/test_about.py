"""「关于 TA」（kind='about'）：TA 的日常小事。不随时间淡去、会被想起来，
但不出现在给用户看的列表和网状图里（Tilia 2026-09-26 定：完全看不见）；导出和清空照样带上。"""
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import importlib

import memory as M
from memory.decay import weight
from memory.embed import FakeEmbedder
from memory.models import Memory

recall = importlib.import_module("memory.recall")
E = FakeEmbedder()
NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)


def test_about_never_decays():
    m = Memory(id=1, user_id=uuid4(), kind="about", content="x", importance=10, valence=0, arousal=0, tags=[],
               resolved=True, created_at=NOW - timedelta(days=3000), updated_at=NOW, last_recalled_at=None,
               recall_count=0)
    assert weight(m, NOW) == 1.0


async def test_about_is_hidden_from_lists_and_graph_but_exported(pool, user_a):
    a = (await M.remember(pool, E, user_a, "燕麦拿铁要半糖", kind="about")).memory
    m = (await M.remember(pool, E, user_a, "下个月十二号考 OSCE")).memory
    assert a.kind == "about"
    assert [x.id for x in await M.list_memories(pool, user_a)] == [m.id]
    assert {x.id for x in await M.list_memories(pool, user_a, include_hidden=True)} == {a.id, m.id}
    assert [x.id for x in await M.list_memories(pool, user_a, kind="about")] == [a.id]
    assert a.id not in {n.id for n in (await M.graph(pool, user_a)).nodes}
    assert "燕麦拿铁要半糖" in [x["content"] for x in (await M.export(pool, user_a))["memories"]]
    assert await M.wipe(pool, user_a) == 2


async def test_about_is_recalled_and_marked(pool, user_a):
    await M.remember(pool, E, user_a, "燕麦拿铁要半糖，不加奶泡", kind="about")
    r = await recall.recall(pool, E, user_a, "燕麦拿铁要半糖，不加奶泡")
    assert [m.kind for m in r.full] == ["about"]


async def test_about_recall_line_carries_kind(pool, user_a):
    for i in range(3):
        await M.remember(pool, E, user_a, f"完全无关的事情 编号{i}")
    await M.remember(pool, E, user_a, "周末喜欢去海边散步看日落", kind="about")
    cfg = M.MemoryConfig(max_full=0)                      # 不给整条，逼它走摘要行
    r = await recall.recall(pool, E, user_a, "周末喜欢去海边散步看日落", cfg=cfg)
    assert [(l.kind, l.snippet) for l in r.lines][:1] == [("about", "周末喜欢去海边散步看日落")]
