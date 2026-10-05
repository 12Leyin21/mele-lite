"""醒来一次 + 巡逻循环（第 5 步）。测试用小满。"""
from datetime import datetime, timedelta, timezone

from cryptography.fernet import Fernet

from api.rooms import Rooms
from brain import accounts, archive, auth
from brain.turn import Deps
from llm.errors import LLMError
from llm.fake import FakeModel
from llm.router import Route
from memory.embed import FakeEmbedder
from patrol import store
from patrol.heartbeat import CHECK_EVERY
from patrol.loop import tick_once
from patrol.wake import BUSY_RETRY, wake_once

NOW = datetime(2026, 9, 28, 5, 0, tzinfo=timezone.utc)        # 新加坡周一 13:00，白天
TZ = "Asia/Singapore"


class OneKey:
    def route_for(self, user_id):
        return Route("fake", "k", "fake-chat", "fake-ledger")


class World:
    async def build(self, pool, script, *, settings=None, keys=None):
        self.pool = pool
        self.acc = await accounts.create_account(pool)
        self.comp = await accounts.create_companion(pool, self.acc)
        await archive.save_settings(pool, self.comp, {"tz": TZ, **(settings or {})})
        self.conv = await accounts.new_conversation(pool, self.acc, self.comp)
        # 联系人建好的时间钉在 NOW 一周前：不然真实时钟刚好在 NOW 前几个小时跑测试时（09-28 就是 NOW 那天），
        # 心跳会当它「刚建好」不醒，几条测试跟着钟点时好时坏
        await pool.execute("UPDATE companions SET created_at = $2 WHERE id = $1", self.comp, NOW - timedelta(days=7))
        self.model = FakeModel(script)
        self.now = NOW

        async def nosleep(_):
            return None
        self.deps = Deps(pool=pool, embedder=FakeEmbedder(), keys=keys or OneKey(), adapter_for=lambda r: self.model,
                         now=lambda: self.now, sleep=nosleep)
        self.rooms = Rooms(0.02)
        return self

    async def say(self, role, text, ago):
        await archive.add_message(self.pool, self.conv, role, text, now=self.now - ago)

    async def heartbeat(self):
        await store.ensure_heartbeat(self.pool, self.acc, self.comp, self.now)
        return (await store.list_clocks(self.pool, self.acc, self.comp, kinds=("heartbeat",)))[0]

    async def clock(self, kind, note="", shape="once", spec=None):
        return await store.add_clock(self.pool, self.acc, self.comp, kind=kind, shape=shape,
                                     spec=spec or {"at": self.now.isoformat()}, note=note, next_at=self.now)

    async def log(self):
        return [(r["reason"], r["outcome"]) for r in
                await self.pool.fetch("SELECT reason, outcome FROM wake_log ORDER BY id")]

    async def roles(self):
        return [m.role for m in await archive.recent(self.pool, self.conv)]


async def test_heartbeat_whim_speaks_pushes_and_streams(pool):
    w = await World().build(pool, ["诶，那本书看完没"])
    await w.say("user", "我去看书了", timedelta(hours=3))
    q = w.rooms.listen(w.conv)
    hb = await w.heartbeat()
    assert await wake_once(w.deps, w.rooms, hb, w.now) == "said"
    said_id = await pool.fetchval("SELECT message_id FROM wake_log WHERE outcome = 'said' AND companion_id = $1", w.comp)
    assert said_id == (await archive.recent(pool, w.conv, 1))[0].id      # 醒来账记着它那句的消息号
    assert await w.log() == [("whim", "said")]
    assert await w.roles() == ["user", "wake", "assistant"]
    assert await pool.fetchval("SELECT text FROM push_queue") == "诶，那本书看完没"
    got = []
    while not q.empty():
        got.append(q.get_nowait())
    assert [g["text"] for g in got if g["type"] == "bubble"] == ["诶，那本书看完没"]
    envelope = w.model.requests[0].messages[-1].text
    assert "心血来潮" not in envelope and "隔了一阵" in envelope and "最后一句是TA说的" in envelope
    assert (await w.heartbeat()).next_at == NOW + CHECK_EVERY


async def test_silent_wake_leaves_chat_alone(pool):
    w = await World().build(pool, ["<silent>"])
    await w.say("user", "晚安", timedelta(hours=3))
    assert await wake_once(w.deps, w.rooms, await w.heartbeat(), w.now) == "silent"
    assert await w.roles() == ["user"] and await w.log() == [("whim", "silent")]
    assert await pool.fetchval("SELECT count(*) FROM push_queue") == 0


async def test_user_clock_silent_gets_asked_again(pool):
    # TA 定的钟：它回了 <silent> 也不算完，再叫一次、明说这次必须开口
    w = await World().build(pool, ["<silent>", "房租交了没呀"])
    assert await wake_once(w.deps, w.rooms, await w.clock("user", "提醒我交房租"), w.now) == "said"
    assert await w.roles() == ["wake", "assistant"] and await w.log() == [("user", "said")]
    assert "我刚才一个字没说" in w.model.requests[1].messages[-1].text
    w2 = await World().build(pool, ["<silent>", "<silent>"])       # 两次都不说：就此打住，不死循环
    assert await wake_once(w2.deps, w2.rooms, await w2.clock("user", "x"), w2.now) == "silent"
    assert len(w2.model.requests) == 2


async def test_self_clock_silent_is_not_asked_again(pool):
    w = await World().build(pool, ["<silent>"])
    assert await wake_once(w.deps, w.rooms, await w.clock("self", "问问面试"), w.now) == "silent"
    assert len(w.model.requests) == 1


async def test_gate_closed_does_nothing(pool):
    w = await World().build(pool, [])
    await w.say("user", "在吗", timedelta(minutes=30))
    assert await wake_once(w.deps, w.rooms, await w.heartbeat(), w.now) == "no"
    assert await w.log() == [] and w.model.requests == []


async def test_brand_new_companion_waits_a_gap(pool):
    w = await World().build(pool, [])
    await pool.execute("UPDATE companions SET created_at = $2 WHERE id = $1", w.comp, NOW)
    w.now = NOW + timedelta(minutes=5)                         # 刚建好：不会一注册就来找
    assert await wake_once(w.deps, w.rooms, await w.heartbeat(), w.now) == "no"


async def test_user_clock_busy_retries_in_a_minute(pool):
    w = await World().build(pool, [])
    w.rooms.room(w.conv).pending.append("TA 正在打字")
    c = await w.clock("user", "提醒吃药", shape="at", spec={"time": "13:00", "days": []})
    assert await wake_once(w.deps, w.rooms, c, w.now) == "skipped_busy"
    assert (await store.get_clock(pool, w.acc, c.id)).next_at == NOW + BUSY_RETRY


async def test_daily_cap_skips_and_logs_user_clock(pool):
    w = await World().build(pool, [], settings={"patrol_level": "low"})       # 一天 6 次
    for i in range(6):
        await store.log_wake(pool, account=w.acc, companion=w.comp, conversation=w.conv,
                             at=NOW - timedelta(minutes=10 + i), reason="whim", clock_id=None, outcome="silent")
    c = await w.clock("user", "交房租")
    assert await wake_once(w.deps, w.rooms, c, w.now) == "skipped_cap"
    assert (await w.log())[-1] == ("user", "skipped_cap")
    assert await store.get_clock(pool, w.acc, c.id) is None                    # 一次性的，跳过也算响完


async def test_self_clock_brings_its_note_then_goes_away(pool):
    w = await World().build(pool, ["面试怎么样啦？"])
    await w.say("user", "我明天面试", timedelta(days=1))
    c = await w.clock("self", "问问面试怎么样")
    assert await wake_once(w.deps, w.rooms, c, w.now) == "said"
    env = w.model.requests[0].messages[-1].text
    assert "这是我之前给自己约的" in env and "我约这个钟时写给自己的：「问问面试怎么样」" in env
    assert await store.count_self(pool, w.comp) == 0 and (await w.log()) == [("self", "said")]


async def test_repeating_user_clock_moves_to_next_day(pool):
    w = await World().build(pool, ["早呀，今天打算做什么？"])
    c = await w.clock("user", "问我今天的安排", shape="at", spec={"time": "13:00", "days": []})
    await wake_once(w.deps, w.rooms, c, w.now)
    assert (await store.get_clock(pool, w.acc, c.id)).next_at == NOW + timedelta(days=1)
    assert "TA 定这个钟时写的：「问我今天的安排」" in w.model.requests[0].messages[-1].text


async def test_three_errors_pause_the_heartbeat(pool):
    w = await World().build(pool, [LLMError("auth", "bad key")] * 3)
    hb = await w.heartbeat()
    for i in range(3):
        w.now = NOW + timedelta(hours=3 * i)
        hb = (await store.list_clocks(pool, w.acc, w.comp, kinds=("heartbeat",)))[0]
        assert await wake_once(w.deps, w.rooms, hb, w.now) == "error"
    hb = (await store.list_clocks(pool, w.acc, w.comp, kinds=("heartbeat",)))[0]
    assert hb.spec == {"errors": 3, "paused": True}
    w.now = NOW + timedelta(hours=12)
    assert await wake_once(w.deps, w.rooms, hb, w.now) == "off"


async def test_trial_over_is_not_an_error(pool):
    w = await World().build(pool, [], keys=auth.DbKeys(pool, auth.KeyBox(Fernet.generate_key()), None))   # 没钥匙也没试用
    for i in range(4):
        w.now = NOW + timedelta(hours=3 * i)
        hb = (await store.list_clocks(pool, w.acc, w.comp, kinds=("heartbeat",))) or [await w.heartbeat()]
        assert await wake_once(w.deps, w.rooms, hb[0], w.now) == "no_key"
    hb = (await store.list_clocks(pool, w.acc, w.comp, kinds=("heartbeat",)))[0]
    assert not hb.spec.get("paused")


async def test_heartbeat_off(pool):
    w = await World().build(pool, [], settings={"heartbeat_on": False})
    assert await wake_once(w.deps, w.rooms, await w.heartbeat(), w.now) == "off"


async def test_tick_adds_heartbeats_and_runs_due_clocks(pool):
    w = await World().build(pool, ["该吃药啦"])
    c = await w.clock("user", "提醒吃药")
    assert await tick_once(w.deps, w.rooms) == 1                  # 心跳刚补上、20 分钟后才看；到点的只有这个钟
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'heartbeat'") == 1
    assert await store.get_clock(pool, w.acc, c.id) is None and (await w.log()) == [("user", "said")]
