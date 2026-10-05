from datetime import date, datetime, timedelta, timezone

from brain import archive
from llm.types import Usage

NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)
DAY = date(2026, 9, 26)


async def test_messages_unrolled_recent_and_rolling(pool, user_a):
    a = await archive.add_message(pool, user_a, "user", "早", now=NOW)
    b = await archive.add_message(pool, user_a, "assistant", "早呀", thinking="她起得早", now=NOW)
    c = await archive.add_message(pool, user_a, "user", "吃了吗", now=NOW + timedelta(minutes=1))
    assert [m.text for m in await archive.unrolled(pool, user_a)] == ["早", "早呀", "吃了吗"]
    assert (await archive.unrolled(pool, user_a))[1].thinking == "她起得早"
    await archive.mark_rolled(pool, user_a, [a.id, b.id])
    assert [m.id for m in await archive.unrolled(pool, user_a)] == [c.id]
    assert [m.text for m in await archive.recent(pool, user_a, limit=2)] == ["早呀", "吃了吗"]


async def test_ledger_upsert_and_delete(pool, user_a):
    await archive.put_ledger(pool, user_a, {DAY: "- 聊了芒果", DAY - timedelta(days=1): "- 去游泳"})
    await archive.put_ledger(pool, user_a, {DAY: "- 聊了芒果\n- 定了周六见"})
    got = await archive.get_ledger(pool, user_a)
    assert list(got) == [DAY - timedelta(days=1), DAY] and "周六" in got[DAY]
    await archive.put_ledger(pool, user_a, {DAY - timedelta(days=1): ""})
    assert list(await archive.get_ledger(pool, user_a)) == [DAY]


async def test_settings_and_state_roundtrip(pool, user_a):
    assert await archive.get_settings(pool, user_a) == {}
    await archive.save_settings(pool, user_a, {"lang": "en", "max_bubbles": None})
    assert await archive.get_settings(pool, user_a) == {"lang": "en", "max_bubbles": None}
    await archive.save_state(pool, user_a, {"turn_count": 3})
    await archive.save_state(pool, user_a, {"turn_count": 4, "last_tools": ["memory_search"]})
    assert await archive.get_state(pool, user_a) == {"turn_count": 4, "last_tools": ["memory_search"]}


async def test_persona_versions(pool, user_a):
    assert await archive.get_persona(pool, user_a) is None
    await archive.save_persona(pool, user_a, {"name": "Lumi"}, now=NOW)
    await archive.save_persona(pool, user_a, {"name": "阿澄"}, now=NOW + timedelta(hours=1))
    assert (await archive.get_persona(pool, user_a))["name"] == "阿澄"
    assert [h["data"]["name"] for h in await archive.persona_history(pool, user_a)] == ["阿澄", "Lumi"]


async def test_usage_accumulates(pool, user_a):
    await archive.add_usage(pool, user_a, DAY, "deepseek-flash", Usage(100, 900, 0, 20), 0.001)
    await archive.add_usage(pool, user_a, DAY, "deepseek-flash", Usage(10, 1000, 0, 30), 0.002)
    await archive.add_usage(pool, user_a, DAY, "custom", Usage(5, 0, 0, 5), None)
    u = await archive.usage_on(pool, user_a, DAY)
    assert (u["calls"], u["input"], u["cache_read"], u["output"]) == (3, 115, 1900, 55)
    assert abs(u["cost_usd"] - 0.003) < 1e-9 and u["unknown_cost_calls"] == 1
    assert (await archive.usage_on(pool, user_a, DAY + timedelta(days=1)))["calls"] == 0


async def test_everything_is_per_user_and_wipe(pool, user_a, user_b):
    await archive.add_message(pool, user_a, "user", "A 的话")
    await archive.put_ledger(pool, user_a, {DAY: "- A 的账"})
    await archive.save_settings(pool, user_a, {"lang": "zh"})
    await archive.save_persona(pool, user_a, {"name": "A 的"})
    await archive.log_turn(pool, user_a, {"turn": 1})
    await archive.add_usage(pool, user_a, DAY, "m", Usage(1, 0, 0, 1), 0.0)
    assert await archive.unrolled(pool, user_b) == []
    assert await archive.get_ledger(pool, user_b) == {}
    assert await archive.get_settings(pool, user_b) == {}
    assert await archive.get_persona(pool, user_b) is None
    assert (await archive.usage_on(pool, user_b, DAY))["calls"] == 0
    exported = await archive.export(pool, user_a)
    assert exported["messages"][0]["text"] == "A 的话" and exported["ledger"] == {"2026-09-26": "- A 的账"}
    await archive.wipe(pool, user_b)
    assert len(await archive.unrolled(pool, user_a)) == 1
    await archive.wipe(pool, user_a)
    assert await archive.export(pool, user_a) == {
        "messages": [], "ledger": {}, "settings": {}, "state": {}, "personas": [], "usage": []}
