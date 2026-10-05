from memory import sticky
from memory.config import MemoryConfig


async def test_sticky_roundtrip(pool, user_a):
    assert await sticky.get_sticky(pool, user_a) == ""
    await sticky.set_sticky(pool, user_a, "她下午去医院，晚上问结果")
    assert await sticky.get_sticky(pool, user_a) == "她下午去医院，晚上问结果"
    await sticky.set_sticky(pool, user_a, "  ")
    assert await sticky.get_sticky(pool, user_a) == ""


async def test_sticky_truncates(pool, user_a):
    saved = await sticky.set_sticky(pool, user_a, "字" * 600, cfg=MemoryConfig(sticky_max_chars=10))
    assert saved == "字" * 10
