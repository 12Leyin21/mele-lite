"""巡逻的表和存取（第 3 步）。"""
import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from brain import accounts
from patrol import store

T0 = datetime(2026, 9, 28, 6, 0, tzinfo=timezone.utc)


async def two_accounts(pool):
    a = await accounts.create_account(pool)
    b = await accounts.create_account(pool)
    ca = await accounts.create_companion(pool, a)
    cb = await accounts.create_companion(pool, b)
    return a, ca, b, cb


async def test_add_list_update_delete_only_own(pool):
    a, ca, b, cb = await two_accounts(pool)
    c = await store.add_clock(pool, a, ca, kind="user", shape="at", spec={"time": "08:00", "days": []},
                              note="问我今天安排", next_at=T0)
    await store.add_clock(pool, a, ca, kind="self", shape="once", spec={"at": T0.isoformat()}, note="问面试", next_at=T0)
    assert [x.note for x in await store.list_clocks(pool, a, ca)] == ["问我今天安排"]          # 默认只列你定的
    assert len(await store.list_clocks(pool, a, ca, kinds=("user", "self"))) == 2
    assert await store.update_clock(pool, b, c.id, note="偷改") is None                         # 别人的
    assert (await store.update_clock(pool, a, c.id, note="提醒吃药")).note == "提醒吃药"
    assert not await store.delete_clock(pool, b, c.id)
    with pytest.raises(PermissionError):
        await store.add_clock(pool, b, ca, kind="user", shape="at", spec={}, note="", next_at=T0)
    assert await store.delete_clock(pool, a, c.id)
    assert await store.count_self(pool, ca) == 1


async def test_self_clocks_hidden_from_user_edits(pool):
    a, ca, *_ = await two_accounts(pool)
    s = await store.add_clock(pool, a, ca, kind="self", shape="once", spec={"at": T0.isoformat()}, note="秘密",
                              next_at=T0)
    assert await store.update_clock(pool, a, s.id, note="看看") is None
    assert not await store.delete_clock(pool, a, s.id)
    assert await store.delete_clock(pool, a, s.id, kinds=("self",))


async def test_one_heartbeat_per_companion(pool):
    a, ca, *_ = await two_accounts(pool)
    await store.ensure_heartbeat(pool, a, ca, T0)
    await store.ensure_heartbeat(pool, a, ca, T0 + timedelta(hours=1))
    hb = await store.list_clocks(pool, a, ca, kinds=("heartbeat",))
    assert len(hb) == 1 and hb[0].next_at == T0


async def test_claim_due_only_once_even_concurrently(pool):
    a, ca, *_ = await two_accounts(pool)
    for i in range(6):
        await store.add_clock(pool, a, ca, kind="user", shape="at", spec={"time": "08:00", "days": []}, note=str(i),
                              next_at=T0 - timedelta(minutes=i))
    await store.add_clock(pool, a, ca, kind="user", shape="at", spec={"time": "09:00", "days": []}, note="later",
                          next_at=T0 + timedelta(hours=1))
    got = await asyncio.gather(*[store.claim_due(pool, T0, limit=4) for _ in range(3)])
    ids = [c.id for batch in got for c in batch]
    assert len(ids) == 6 and len(set(ids)) == 6                                 # 六个到点的各被领一次
    assert await store.claim_due(pool, T0) == []                                # 领走的先占五分钟
    assert len(await store.claim_due(pool, T0 + timedelta(minutes=6))) == 6


async def test_reschedule_none_deletes(pool):
    a, ca, *_ = await two_accounts(pool)
    c = await store.add_clock(pool, a, ca, kind="self", shape="once", spec={"at": T0.isoformat()}, note="", next_at=T0)
    await store.reschedule(pool, c.id, None)
    assert await store.count_self(pool, ca) == 0


async def test_wake_counts(pool):
    a, ca, *_ = await two_accounts(pool)
    conv = await accounts.new_conversation(pool, a, ca)

    async def log(minutes, outcome, reason="whim"):
        await store.log_wake(pool, account=a, companion=ca, conversation=conv, at=T0 + timedelta(minutes=minutes),
                             reason=reason, clock_id=None, outcome=outcome)
    await log(0, "said", "night_awake")
    for m in (10, 20, 30):
        await log(m, "silent")
    await log(35, "skipped_cap")
    assert await store.quiet_streak(pool, ca, last_user_at=None) == 3
    assert await store.quiet_streak(pool, ca, last_user_at=T0 + timedelta(minutes=15)) == 2   # TA 回来过，从那以后数
    assert await store.wakes_since(pool, ca, T0) == 4                           # 跳过的不算醒
    assert await store.night_found(pool, ca, T0 - timedelta(hours=1)) == 1
    assert await store.last_woke_at(pool, ca) == T0 + timedelta(minutes=30)


async def test_deleting_companion_takes_clocks_and_log(pool):
    a, ca, *_ = await two_accounts(pool)
    cb = await accounts.create_companion(pool, a)
    await store.ensure_heartbeat(pool, a, cb, T0)
    await store.log_wake(pool, account=a, companion=cb, conversation=None, at=T0, reason="whim", clock_id=None,
                         outcome="silent")
    await accounts.delete_companion(pool, a, cb)
    assert await pool.fetchval("SELECT count(*) FROM clocks") == 0
    assert await pool.fetchval("SELECT count(*) FROM wake_log") == 0
