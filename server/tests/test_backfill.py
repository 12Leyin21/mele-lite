import importlib

from memory import people, store

# memory.backfill 这个名字被对外同名函数占了，这里要的是模块本身
backfill = importlib.import_module("memory.backfill")
from memory.embed import FakeEmbedder


class Broken:
    dim = 1024

    def embed(self, texts):
        raise RuntimeError("down")


async def test_backfill_fills_missing(pool, user_a, user_b):
    await store.remember(pool, Broken(), user_a, "先没向量")
    await people.upsert_person(pool, Broken(), user_b, "阿杰")
    assert await backfill.backfill(pool, Broken()) == 0
    assert await backfill.backfill(pool, FakeEmbedder()) == 2
    assert all(m.has_embedding for m in await store.list_memories(pool, user_a))
    assert await backfill.backfill(pool, FakeEmbedder()) == 0
