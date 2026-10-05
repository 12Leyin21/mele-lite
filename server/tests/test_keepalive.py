"""Claude 缓存保活（09-29，Tilia：忙的人一天就聊几次，但不想缓存扑空）：开关默认关；每 55 分钟用 max_tokens=0 原样续一次缓存前缀；
TA 的睡觉时间停、一天封顶；TA 一说话从头算。测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from brain import accounts, archive
from brain import keepalive as K
from brain.scope import Scope
from brain.settings import Settings
from llm.anthropic_adapter import AnthropicAdapter
from llm.router import Route
from llm.types import Block, ChatRequest, Msg, Usage
from test_anthropic_adapter import Blk, FakeClient

NOW = datetime(2026, 9, 29, 2, 0, tzinfo=timezone.utc)          # 新加坡 10:00
REQ = ChatRequest(model="claude-sonnet-5", system=[Block("壹", cache=True)],
                  messages=[Msg("user", "早"), Msg("assistant", "早呀", cache=True), Msg("user", "〔现在〕…\n\n今天好累")])


class CreateOnly(FakeClient):
    """只记 create（保活不走流式）。"""

    def __init__(self):
        super().__init__()
        self.created = []

        async def create(**kw):
            self.created.append(kw)
            return Blk(content=[], stop_reason="max_tokens", usage=Blk(
                input_tokens=1, output_tokens=0, cache_read_input_tokens=900, cache_creation_input_tokens=0,
                cache_creation=None))
        self.messages.create = create


async def test_adapter_keepalive_cuts_after_the_last_bookmark():
    fc = CreateOnly()
    usage = await AnthropicAdapter("k", client=fc).keepalive(REQ)
    kw = fc.created[0]
    assert kw["max_tokens"] == 0 and "stream" not in kw
    assert [m["role"] for m in kw["messages"]] == ["user", "assistant", "user"]
    assert kw["messages"][1]["content"][0]["cache_control"] == {"type": "ephemeral", "ttl": "1h"}
    assert kw["messages"][2]["content"] == [{"type": "text", "text": "."}]     # 易变区那条换成一个点，不按全价付它
    assert usage.cache_read == 900 and usage.output == 0
    assert fc.messages.calls == []                                             # 没走流式


class FakeAdapter:
    def __init__(self):
        self.sent = []

    async def keepalive(self, req):
        self.sent.append(req)
        return Usage(input=1, cache_read=900)


async def world(pool, **settings):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    conv = await accounts.new_conversation(pool, acc, comp)
    await archive.save_settings(pool, comp, {"tz": "Asia/Singapore", "sleep_from": "23:00", "sleep_to": "07:00",
                                             "cache_keepalive": True, **settings})
    return Scope(acc, comp, conv)


ROUTE = Route("anthropic", "k", "claude-sonnet-5", "claude-haiku-4-5")


async def test_tick_refreshes_every_55_minutes(pool):
    K.reset()
    scope, ad = await world(pool), FakeAdapter()
    K.remember(scope, ROUTE, REQ, NOW, enabled=True)
    assert await K.tick(pool, NOW + timedelta(minutes=50), lambda r: ad) == 0
    assert await K.tick(pool, NOW + timedelta(minutes=55), lambda r: ad) == 1
    assert await K.tick(pool, NOW + timedelta(minutes=60), lambda r: ad) == 0       # 刚续过
    assert await K.tick(pool, NOW + timedelta(minutes=110), lambda r: ad) == 1
    assert len(ad.sent) == 2
    used = await pool.fetchrow("SELECT calls, cache_read FROM usage_daily WHERE user_id = $1", scope.account)
    assert (used["calls"], used["cache_read"]) == (2, 1800)                        # 花的钱记在账号上


async def test_tick_stops_at_bedtime_cap_off_and_other_providers(pool):
    K.reset()
    scope, ad = await world(pool), FakeAdapter()
    late = datetime(2026, 9, 29, 15, 30, tzinfo=timezone.utc)                     # 新加坡 23:30，睡了
    K.remember(scope, ROUTE, REQ, late - timedelta(hours=1), enabled=True)
    assert await K.tick(pool, late, lambda r: ad) == 0
    assert not K.tracked(scope.conversation)                                      # 睡了就放手，醒来等 TA 先开口

    K.remember(scope, ROUTE, REQ, NOW, enabled=True)
    for i in range(1, K.DAILY_CAP + 3):
        await K.tick(pool, NOW + timedelta(minutes=55 * i), lambda r: ad)
    assert len(ad.sent) <= K.DAILY_CAP

    off = await world(pool, cache_keepalive=False)
    K.remember(off, ROUTE, REQ, NOW, enabled=False)
    assert not K.tracked(off.conversation)
    turned_off = await world(pool)                                                # 记下以后 TA 在设置里关掉了
    K.remember(turned_off, ROUTE, REQ, NOW, enabled=True)
    await archive.save_settings(pool, turned_off.companion, {"tz": "Asia/Singapore", "cache_keepalive": False})
    await K.tick(pool, NOW + timedelta(hours=1), lambda r: ad)
    assert not K.tracked(turned_off.conversation)
    ds = await world(pool)
    K.remember(ds, Route("deepseek", "k", "deepseek-flash", "deepseek-flash"), REQ, NOW, enabled=True)
    assert not K.tracked(ds.conversation)


async def test_setting_defaults_off():
    assert Settings().cache_keepalive is False


def test_forget_on_new_turn():
    K.reset()
    s = Scope(uuid4(), uuid4(), uuid4())
    K.remember(s, ROUTE, REQ, NOW, enabled=True)
    assert K.tracked(s.conversation)
    K.forget(s.conversation)
    assert not K.tracked(s.conversation)
