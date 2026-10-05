from datetime import datetime, timedelta, timezone

import pytest

import importlib

from memory import store

# memory.search 这个名字被对外同名函数占了，这里要的是模块本身
search = importlib.import_module("memory.search")
from memory.embed import FakeEmbedder

E = FakeEmbedder()
NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)


def test_rrf_fuse_rewards_agreement():
    fused = search.rrf_fuse([[1, 2, 3], [3, 1]], k=60)
    assert fused[1] > fused[3] > fused[2]
    assert fused[1] == pytest.approx(1 / 61 + 1 / 62)


async def seed(pool, user):
    for text in ["小满对芒果过敏", "小满周二晚上去游泳", "年糕是一只橘猫", "Mia is training for a half marathon"]:
        await store.remember(pool, E, user, text, now=NOW)


async def test_search_finds_the_relevant_one_first(pool, user_a):
    await seed(pool, user_a)
    hits = await search.search(pool, E, user_a, "芒果能吃吗", now=NOW)
    assert hits[0].memory.content == "小满对芒果过敏"
    assert hits[0].keyword is True and hits[0].sim is not None


async def test_search_english(pool, user_a):
    await seed(pool, user_a)
    hits = await search.search(pool, E, user_a, "marathon training plan", now=NOW)
    assert hits[0].memory.content.startswith("Mia is training")


async def test_search_touches_returned(pool, user_a):
    await seed(pool, user_a)
    later = NOW + timedelta(days=1)
    hits = await search.search(pool, E, user_a, "芒果", limit=1, now=later)
    m = await store.get(pool, user_a, hits[0].memory.id)
    assert m.last_recalled_at == later and m.recall_count == 1


async def test_search_without_touch(pool, user_a):
    await seed(pool, user_a)
    hits = await search.search(pool, E, user_a, "芒果", limit=1, touch=False, now=NOW)
    assert (await store.get(pool, user_a, hits[0].memory.id)).recall_count == 0


class Broken:
    dim = 1024

    def embed(self, texts):
        raise RuntimeError("down")


async def test_search_falls_back_to_keywords(pool, user_a):
    await seed(pool, user_a)
    hits = await search.search(pool, Broken(), user_a, "芒果", now=NOW)
    assert hits and hits[0].memory.content == "小满对芒果过敏"
    assert hits[0].sim is None and hits[0].keyword is True


async def test_older_memory_ranks_lower_when_equally_relevant(pool, user_a):
    await store.remember(pool, E, user_a, "游泳 周二", now=NOW - timedelta(days=200))
    await store.remember(pool, E, user_a, "游泳 周四", now=NOW)
    hits = await search.search(pool, E, user_a, "游泳", now=NOW, touch=False)
    assert hits[0].memory.content == "游泳 周四"
