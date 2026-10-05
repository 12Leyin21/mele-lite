"""免费额度（iOS 第二块第 5 步，Tilia 09-28）：按 token 折成钱扣，第一次给得多，之后每天早上 5 点补到一小份、不累加。
测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from brain import accounts, auth
from llm.router import Route
from llm.types import Usage
from test_api import SECRET, Env

POLICY = auth.TrialPolicy(first_micro=50_000, daily_micro=10_000)       # 0.05 / 0.01 美元
T0 = datetime(2026, 9, 28, 4, 0, tzinfo=timezone.utc)                   # 新加坡 12:00
TZ_SG = "Asia/Singapore"


async def test_new_account_gets_first_grant_then_daily_refill_without_stacking(pool):
    acc = await accounts.create_account(pool)
    assert await auth.trial_balance(pool, acc, T0, TZ_SG, POLICY) == 50_000
    await auth.charge_trial(pool, acc, 45_000)
    assert await auth.trial_balance(pool, acc, T0 + timedelta(hours=10), TZ_SG, POLICY) == 5_000     # 新加坡 22:00，还没换日
    nxt = T0 + timedelta(hours=17, minutes=1)                                                       # 新加坡次日 05:01
    assert await auth.trial_balance(pool, acc, nxt, TZ_SG, POLICY) == 10_000                        # 补到每日份
    assert await auth.trial_balance(pool, acc, nxt + timedelta(hours=1), TZ_SG, POLICY) == 10_000   # 同一天不再补
    await auth.charge_trial(pool, acc, 1_000)
    later = nxt + timedelta(days=3)
    assert await auth.trial_balance(pool, acc, later, TZ_SG, POLICY) == 10_000                      # 不累加


async def test_leftover_bigger_than_daily_is_kept(pool):
    acc = await accounts.create_account(pool)
    await auth.trial_balance(pool, acc, T0, TZ_SG, POLICY)
    await auth.charge_trial(pool, acc, 10_000)                                   # 还剩 40_000
    assert await auth.trial_balance(pool, acc, T0 + timedelta(days=1), TZ_SG, POLICY) == 40_000


async def test_reused_device_gets_only_the_daily_part(pool):
    a = await accounts.create_account(pool)
    b = await accounts.create_account(pool)
    assert await auth.claim_trial_device(pool, a, "phone-1", secret=SECRET)
    assert not await auth.claim_trial_device(pool, b, "phone-1", secret=SECRET)
    assert await auth.trial_balance(pool, b, T0, TZ_SG, POLICY) == 10_000             # 没有礼包，只有每日份
    assert await auth.trial_balance(pool, a, T0, TZ_SG, POLICY) == 50_000


async def test_charge_never_goes_below_zero(pool):
    acc = await accounts.create_account(pool)
    await auth.trial_balance(pool, acc, T0, TZ_SG, POLICY)
    await auth.charge_trial(pool, acc, 999_999)
    assert await auth.trial_balance(pool, acc, T0, TZ_SG, POLICY) == 0


def usage(inp):
    return {"text": "好呀", "usage": Usage(input=inp, output=0)}


async def trial_env(pool, script):
    e = Env(pool, script)
    route = Route("fake", "ours", "deepseek-flash", "deepseek-flash", trial=True)      # 按 DeepSeek Flash 的价扣
    e.deps.keys = auth.DbKeys(pool, e.app.state.api.cfg.box, route, policy=POLICY)
    t = await e.login()
    return e, t


async def test_turns_are_charged_by_cost_until_quota_runs_out(pool):
    # 100k 输入 token × 0.30 美元/百万 = 0.03 美元 = 30_000 微美元
    e, t = await trial_env(pool, [usage(100_000), usage(100_000)])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "reply_wait": 0}})
        me = (await c.get("/me")).json()
        assert me["trial"]["ratio"] == 1.0 and me["trial"]["refill_at"]
        acc = UUID(me["id"])
        from brain.turn import run_turn
        from brain.scope import Scope

        async def emit(_):
            return None
        scope = Scope(acc, UUID(comp["id"]), UUID(conv["id"]))
        assert (await run_turn(e.deps, scope, "在吗", emit)).said
        left = await auth.trial_balance(pool, acc, e.deps.now(), TZ_SG, POLICY)
        assert left == 20_000
        assert (await c.get("/me")).json()["trial"]["ratio"] == 0.4
        assert (await run_turn(e.deps, scope, "再聊一句", emit)).said          # 扣到 0（不欠账）
        out = await run_turn(e.deps, scope, "还在吗", emit)
        assert out.error == "trial_over"


async def test_first_meet_is_free(pool):
    e, t = await trial_env(pool, [usage(100_000)])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        acc = UUID((await c.get("/me")).json()["id"])
        from brain.turn import run_turn
        from brain.scope import Scope

        async def emit(_):
            return None
        await run_turn(e.deps, Scope(acc, UUID(comp["id"]), UUID(conv["id"])), "", emit, wake="〔初见〕", free_trial=True)
        assert await auth.trial_balance(pool, acc, e.deps.now(), "UTC", POLICY) == 50_000
