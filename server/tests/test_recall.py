from datetime import datetime, timezone
from uuid import uuid4

import numpy as np

import importlib

from memory import people, store

# memory.recall 这个名字被对外同名函数占了，这里要的是模块本身
recall = importlib.import_module("memory.recall")
from memory.embed import FakeEmbedder
from memory.models import Memory

E = FakeEmbedder()
NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)
MED = recall.LEVELS["medium"]


def fake_mem(i):
    return Memory(id=i, user_id=uuid4(), kind="memory", content=f"m{i}", importance=5, valence=0,
                  arousal=0, tags=[], resolved=True, created_at=NOW, updated_at=NOW,
                  last_recalled_at=None, recall_count=0)


def cand(i, z=0.0, sim=0.0, keyword=False):
    return recall.Candidate(memory=fake_mem(i), sim=sim, z=z, keyword=keyword)


def test_worth_recalling():
    assert not recall.worth_recalling("好的")
    assert not recall.worth_recalling("哈哈哈哈")
    assert not recall.worth_recalling("ok thanks")
    assert not recall.worth_recalling("😂😂")
    assert recall.worth_recalling("我妈生日快到了送什么好")
    assert recall.worth_recalling("my knee hurts again")


def test_zscores():
    z = recall.zscores(np.array([0.1, 0.1, 0.1, 0.9]))
    assert z[3] > 1.5 and abs(z[0] - z[1]) < 1e-9


def test_classify_by_z_with_keyword_bonus():
    assert recall.classify(cand(1, z=MED.full_z), MED, small=False) == "full"
    assert recall.classify(cand(1, z=MED.full_zk, keyword=True), MED, small=False) == "full"
    assert recall.classify(cand(1, z=MED.full_zk), MED, small=False) == "line"
    assert recall.classify(cand(1, z=MED.line_z - 0.01), MED, small=False) == "none"


def test_classify_small_collection_uses_similarity():
    assert recall.classify(cand(1, sim=MED.full_sim), MED, small=True) == "full"
    assert recall.classify(cand(1, sim=MED.line_sim), MED, small=True) == "line"
    assert recall.classify(cand(1, sim=MED.line_sim - 0.01), MED, small=True) == "none"


def test_pick_caps_demotes_and_skips_shown():
    cs = [cand(i, z=10 - i) for i in range(1, 7)]      # 全都够「整条」
    full, lines = recall.pick(cs, MED, small=False, already_shown={2},
                              max_full=2, max_lines=3)
    assert [c.memory.id for c in full] == [1, 3]        # 2 递过了，跳过
    assert [c.memory.id for c in lines] == [4, 5, 6]    # 超出整条上限的降成摘要行


def test_snippet():
    assert recall.snippet("短", 80) == "短"
    assert recall.snippet("长" * 100, 80) == "长" * 80 + "…"


async def test_recall_small_collection_end_to_end(pool, user_a):
    await store.remember(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", now=NOW)
    await store.remember(pool, E, user_a, "周二晚上去游泳", now=NOW)
    r = await recall.recall(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", level="medium", now=NOW)
    assert [m.content for m in r.full] == ["小满对芒果过敏，吃了嘴唇会肿"]
    assert r.lines == []
    m = await store.get(pool, user_a, r.full[0].id)
    assert m.recall_count == 0 and m.last_recalled_at is None   # 09-28 起浮现只读：浮上来不算被想起，真用上才算


async def test_recall_uses_z_when_many_memories(pool, user_a):
    for i in range(25):
        await store.remember(pool, E, user_a, f"无关的日常记录 第{i}条 编号{i * 7919}", now=NOW)
    await store.remember(pool, E, user_a, "年糕是一只四岁的橘猫，上周刚打了疫苗", now=NOW)
    r = await recall.recall(pool, E, user_a, "年糕是一只四岁的橘猫，上周刚打了疫苗", now=NOW)
    assert "年糕是一只四岁的橘猫，上周刚打了疫苗" in [m.content for m in r.full]


async def test_recall_off_and_small_talk_still_pass_people(pool, user_a):
    await people.upsert_person(pool, E, user_a, "阿杰", relation="好朋友")
    await store.remember(pool, E, user_a, "阿杰在悉尼做建筑师")
    off = await recall.recall(pool, E, user_a, "阿杰来了", level="off")
    assert off.full == [] and off.lines == [] and [p.name for p in off.people] == ["阿杰"]


async def test_recall_respects_already_shown(pool, user_a):
    p = await people.upsert_person(pool, E, user_a, "阿杰")
    m = (await store.remember(pool, E, user_a, "阿杰在悉尼做建筑师")).memory
    r = await recall.recall(pool, E, user_a, "阿杰在悉尼做建筑师", already_shown={p.id, m.id})
    assert r.full == [] and r.lines == [] and r.people == []


async def test_recall_skips_memories_whose_source_is_still_in_context(pool, user_a):
    await store.remember(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", now=NOW)
    later = datetime(2026, 9, 26, 13, tzinfo=timezone.utc)
    r = await recall.recall(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", in_context_since=NOW, now=later)
    assert r.full == [] and r.lines == []                                      # 记下它的那段原文还在眼前
    r = await recall.recall(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", in_context_since=later, now=later)
    assert [m.content for m in r.full] == ["小满对芒果过敏，吃了嘴唇会肿"]      # 原文卷走了，才靠联想


async def test_recall_excludes_core(pool, user_a):
    await store.remember(pool, E, user_a, "钉住的核心：她叫小满", kind="core")
    r = await recall.recall(pool, E, user_a, "钉住的核心：她叫小满")
    assert r.full == [] and r.lines == []              # 核心每轮都在壹层，不重复浮现


class Broken:
    dim = 1024

    def embed(self, texts):
        raise RuntimeError("down")


async def test_recall_with_model_down_only_people(pool, user_a):
    await people.upsert_person(pool, E, user_a, "阿杰")
    await store.remember(pool, E, user_a, "阿杰在悉尼做建筑师")
    r = await recall.recall(pool, Broken(), user_a, "阿杰在悉尼做建筑师吗")
    assert r.full == [] and r.lines == [] and [p.name for p in r.people] == ["阿杰"]


async def test_mark_used_only_counts_memories_the_reply_really_used(pool, user_a):
    """09-28 召回只读：浮上来的记忆，回复里真用上了（共用两个以上有意义的词）才算被想起、才加分。"""
    used = (await store.remember(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", now=NOW)).memory
    idle = (await store.remember(pool, E, user_a, "小满周二晚上去游泳", now=NOW)).memory
    got = await recall.mark_used(pool, user_a, [used.id, idle.id], "芒果可别碰啊，上次嘴唇肿成那样", names=["小满"], now=NOW)
    assert got == [used.id]
    assert (await store.get(pool, user_a, used.id)).recall_count == 1
    assert (await store.get(pool, user_a, idle.id)).recall_count == 0
    assert await recall.mark_used(pool, user_a, [idle.id], "小满晚安", names=["小满"], now=NOW) == []   # 只共用称呼不算


async def test_recall_skips_paraphrase_of_something_already_shown(pool, user_a, monkeypatch):
    """09-28 语义去重：这一潮已经递过的那件事，换个说法的那条也不再递；同一轮里两条说的是一件事，只递一条。"""
    a = (await store.remember(pool, E, user_a, "小满最怕打针", now=NOW)).memory
    b = (await store.remember(pool, E, user_a, "小满最怕的就是打针", now=NOW)).memory
    # 假向量没有「意思相近」，这里直接把两条的相似度钉成很像
    monkeypatch.setattr(recall, "_cosines", lambda xs, ys: np.full((len(xs), len(ys)), 0.95))
    r = await recall.recall(pool, E, user_a, "小满最怕的就是打针", now=NOW, already_shown={a.id})
    assert b.id not in [m.id for m in r.full] + [l.memory_id for l in r.lines]
    r = await recall.recall(pool, E, user_a, "小满最怕的就是打针", now=NOW)
    assert len(r.full) + len(r.lines) == 1
