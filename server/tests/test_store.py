from datetime import datetime, timedelta, timezone

import pytest

from memory import store
from memory.config import MemoryConfig
from memory.embed import FakeEmbedder

E = FakeEmbedder()
NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)


async def test_remember_and_get(pool, user_a):
    r = await store.remember(pool, E, user_a, "小满对芒果过敏", importance=8, tags=["健康"],
                             arousal=0.4, now=NOW)
    assert not r.merged
    m = await store.get(pool, user_a, r.memory.id)
    assert m.content == "小满对芒果过敏" and m.importance == 8 and m.tags == ["健康"]
    assert m.has_embedding and m.created_at == NOW


async def test_remember_clamps_and_validates(pool, user_a):
    r = await store.remember(pool, E, user_a, "x", importance=99, valence=5, arousal=-1)
    assert (r.memory.importance, r.memory.valence, r.memory.arousal) == (10, 1.0, 0.0)
    with pytest.raises(ValueError):
        await store.remember(pool, E, user_a, "   ")
    with pytest.raises(ValueError):
        await store.remember(pool, E, user_a, "x", kind="nope")


async def test_near_duplicate_merges(pool, user_a):
    a = await store.remember(pool, E, user_a, "小满对芒果过敏", importance=5, tags=["健康"], now=NOW)
    b = await store.remember(pool, E, user_a, "小满对芒果过敏", importance=9, tags=["饮食"],
                             now=NOW + timedelta(days=1))
    assert b.merged and b.memory.id == a.memory.id
    assert b.memory.importance == 9
    assert set(b.memory.tags) == {"健康", "饮食"}
    assert b.memory.recall_count == 1
    assert len(await store.list_memories(pool, user_a)) == 1


async def test_different_things_do_not_merge(pool, user_a):
    await store.remember(pool, E, user_a, "小满对芒果过敏")
    r = await store.remember(pool, E, user_a, "周二晚上去游泳")
    assert not r.merged
    assert len(await store.list_memories(pool, user_a)) == 2


async def test_merge_threshold_is_configurable(pool, user_a):
    cfg = MemoryConfig(merge_threshold=1.01)   # 永远不合并
    await store.remember(pool, E, user_a, "一样的话", cfg=cfg)
    r = await store.remember(pool, E, user_a, "一样的话", cfg=cfg)
    assert not r.merged


class Broken:
    dim = 1024

    def embed(self, texts):
        raise RuntimeError("down")


async def test_store_without_embedding_when_model_down(pool, user_a):
    r = await store.remember(pool, Broken(), user_a, "模型挂了也要记下")
    assert not r.memory.has_embedding and not r.merged


async def test_update_pin_resolve_delete(pool, user_a):
    m = (await store.remember(pool, E, user_a, "下个月考 OSCE")).memory
    u = await store.update(pool, E, user_a, m.id, content="下个月 12 号考 OSCE", importance=9)
    assert u.content == "下个月 12 号考 OSCE" and u.importance == 9
    assert (await store.pin(pool, user_a, m.id)).kind == "core"
    assert (await store.pin(pool, user_a, m.id, pinned=False)).kind == "memory"
    assert (await store.resolve(pool, user_a, m.id)).resolved is True
    assert await store.delete(pool, user_a, m.id) is True
    assert await store.get(pool, user_a, m.id) is None
    assert await store.delete(pool, user_a, m.id) is False


async def test_list_newest_first_and_filter_kind(pool, user_a):
    await store.remember(pool, E, user_a, "第一条", now=NOW)
    await store.remember(pool, E, user_a, "第二条完全不同的内容", kind="core", now=NOW + timedelta(hours=1))
    ms = await store.list_memories(pool, user_a)
    assert [m.content for m in ms] == ["第二条完全不同的内容", "第一条"]
    assert [m.kind for m in await store.list_memories(pool, user_a, kind="core")] == ["core"]


async def test_touch_updates_recall(pool, user_a):
    m = (await store.remember(pool, E, user_a, "被想起", now=NOW)).memory
    later = NOW + timedelta(days=3)
    await store.touch(pool, user_a, [m.id], later)
    t = await store.get(pool, user_a, m.id)
    assert t.last_recalled_at == later and t.recall_count == 1


async def test_export_and_wipe(pool, user_a):
    await store.remember(pool, E, user_a, "要导出的")
    await pool.execute("INSERT INTO sticky_notes (user_id, text) VALUES ($1, '便利贴')", user_a)
    data = await store.export(pool, user_a)
    assert data["memories"][0]["content"] == "要导出的"
    assert data["sticky"] == "便利贴"
    assert await store.wipe(pool, user_a) == 1
    assert await store.list_memories(pool, user_a) == []
    assert (await store.export(pool, user_a))["sticky"] == ""


async def test_nearest(pool, user_a):
    assert await store.nearest(pool, E, user_a, "小满对芒果过敏") is None
    m = (await store.remember(pool, E, user_a, "小满对芒果过敏")).memory
    await store.remember(pool, E, user_a, "周二晚上去游泳")
    got, sim = await store.nearest(pool, E, user_a, "小满对芒果过敏")
    assert got.id == m.id and sim > 0.99
    assert await store.nearest(pool, E, user_a, "小满对芒果过敏", kinds=("about",)) is None


async def test_near_duplicate_catches_shared_rare_word(pool, user_a):
    """09-27：星际穿越记了两遍，相似度只有 0.67，不到 0.75 的线；共用一个在别处几乎不出现的词就拦下来问。"""
    cfg = MemoryConfig(similar_guard=0.99, rare_guard_sim=0.1)      # 假向量的相似度不准，只测「少见的词」这一路
    movie = (await store.remember(pool, E, user_a, "小满和男朋友在家看了星际穿越", now=NOW)).memory
    await store.remember(pool, E, user_a, "小满在墨尔本读护理", now=NOW)
    await store.remember(pool, E, user_a, "小满护理实习排白班", now=NOW)
    got = await store.near_duplicate(pool, E, user_a, "小满第二遍看星际穿越又哭了", cfg=cfg)
    assert got is not None and got[0].id == movie.id and "星际" in got[2]
    assert await store.near_duplicate(pool, E, user_a, "小满护理考试过了", cfg=cfg) is None     # 护理到处都有，不算


async def test_near_duplicate_plain_similarity_still_counts(pool, user_a):
    m = (await store.remember(pool, E, user_a, "小满对芒果过敏", now=NOW)).memory
    got = await store.near_duplicate(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿起来，家里要备药", cfg=MemoryConfig(similar_guard=0.5))
    assert got is not None and got[0].id == m.id and got[2] == []


async def test_rewrite_sets_clock_but_metadata_edit_does_not(pool, user_a):
    # 10-01：内容改写 = 这件事又有新进展，淡去的时钟拨回改写那天；只改重要性、标签不算
    r = await store.remember(pool, E, user_a, "小满在准备雅思考试", now=NOW)
    assert r.memory.rewritten_at is None
    later = NOW + timedelta(days=40)
    m = await store.update(pool, E, user_a, r.memory.id, importance=9, tags=["考试"], now=later)
    assert m.rewritten_at is None
    m = await store.update(pool, E, user_a, r.memory.id, content="小满雅思考了 7.5，准备申请学校", now=later)
    assert m.rewritten_at == later
    assert (await store.get(pool, user_a, m.id)).rewritten_at == later


async def test_merge_sets_rewritten_at(pool, user_a):
    a = await store.remember(pool, E, user_a, "小满对芒果过敏", now=NOW)
    later = NOW + timedelta(days=10)
    b = await store.remember(pool, E, user_a, "小满对芒果过敏", now=later)
    assert b.merged and b.memory.id == a.memory.id and b.memory.rewritten_at == later
