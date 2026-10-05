"""称呼停用词（09-28，召回改造第 1 步）：它的名字、昵称、用户的名字，加上这个用户记忆里太常见的词，
不进关键词榜——「一个常用称呼就能喊坏整张榜」。按用户算，每个人的称呼不一样。"""
import importlib

from memory import store
from memory.embed import FakeEmbedder

stopwords = importlib.import_module("memory.stopwords")
search = importlib.import_module("memory.search")
words = importlib.import_module("memory.words")
E = FakeEmbedder()


def test_tokens_drop_extra_stopwords():
    assert "小满" in words.tokens("小满今天吃了芒果")
    assert words.tokens("小满今天吃了芒果", stop={"小满"}) == [t for t in words.tokens("小满今天吃了芒果") if t != "小满"]
    assert words.tsquery("小满 Lumi", stop={"小满", "lumi"}) == ""


def test_name_tokens_cover_whole_name_and_pieces():
    got = stopwords.name_tokens(["Lumi", "露露", "盛小满", ""])
    assert {"lumi", "露露", "盛小满"} <= got


async def test_frequent_words_become_stopwords_per_user(pool, user_a, user_b):
    for i in range(12):
        await store.remember(pool, E, user_a, f"小满第{i}件事：{['游泳', '面包', '考试', '年糕'][i % 4]}{i}")
    await store.remember(pool, E, user_b, "小满是我朋友的名字")
    auto = await stopwords.frequent(pool, user_a)
    assert "小满" in auto and "年糕" not in auto            # 12 条里 12 条都有 → 停；只在 3 条里 → 留
    assert "小满" not in await stopwords.frequent(pool, user_b)   # 别人的库不受影响
    stop = await stopwords.for_user(pool, user_a, ["Lumi"])
    assert {"小满", "lumi"} <= stop


async def test_frequent_needs_enough_docs(pool, user_a):
    for i in range(3):
        await store.remember(pool, E, user_a, f"小满第{i}件事")
    assert await stopwords.frequent(pool, user_a) == frozenset()   # 记忆太少不自动停，免得把真话题停掉


async def test_keyword_ids_ignore_names(pool, user_a):
    ids = [(await store.remember(pool, E, user_a, t)).memory.id
           for t in ["小满对芒果过敏", "小满周二去游泳", "Lumi 答应小满陪她复盘"]]
    assert set(await search.keyword_ids(pool, user_a, "小满", 10)) == set(ids)            # 以前：一个名字命中全库
    assert await search.keyword_ids(pool, user_a, "Lumi 小满", 10, names=["Lumi", "小满"]) == []
    assert await search.keyword_ids(pool, user_a, "小满 芒果", 10, names=["小满"]) == [ids[0]]
