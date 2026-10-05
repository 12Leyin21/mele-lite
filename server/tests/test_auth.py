from datetime import datetime, timedelta, timezone

import pytest
from cryptography.fernet import Fernet

from brain import accounts, archive, auth
from brain.scope import Scope
from brain.turn import Deps, run_turn
from llm.fake import FakeModel
from llm.router import Route
from llm.types import Usage
from memory.embed import FakeEmbedder

NOW = datetime(2026, 9, 27, 12, tzinfo=timezone.utc)
SECRET = "test-secret"


async def test_email_code_login_creates_account_with_lumi(pool):
    code = await auth.request_code(pool, " Xiaoman@Example.com ", secret=SECRET, now=NOW)
    assert len(code) == 6 and code.isdigit()
    with pytest.raises(auth.AuthError, match="刚发过"):
        await auth.request_code(pool, "xiaoman@example.com", secret=SECRET, now=NOW + timedelta(seconds=10))
    with pytest.raises(auth.AuthError, match="不对"):
        await auth.verify_code(pool, "xiaoman@example.com", "000000" if code != "000000" else "111111",
                               secret=SECRET, now=NOW)
    acc = await auth.verify_code(pool, "xiaoman@example.com", code, secret=SECRET, now=NOW)
    comps = await accounts.list_companions(pool, acc)
    assert len(comps) == 1 and len(await accounts.list_conversations(pool, acc, comps[0])) == 1   # 送一个 Lumi
    with pytest.raises(auth.AuthError, match="过期"):                                             # 用过就没了
        await auth.verify_code(pool, "xiaoman@example.com", code, secret=SECRET, now=NOW)
    code2 = await auth.request_code(pool, "xiaoman@example.com", secret=SECRET, now=NOW + timedelta(minutes=2))
    assert await auth.verify_code(pool, "xiaoman@example.com", code2, secret=SECRET,
                                  now=NOW + timedelta(minutes=3)) == acc                         # 同一个邮箱回来是同一个账号


async def test_code_expires_and_locks_after_five_tries(pool):
    code = await auth.request_code(pool, "a@b.co", secret=SECRET, now=NOW)
    with pytest.raises(auth.AuthError, match="过期"):
        await auth.verify_code(pool, "a@b.co", code, secret=SECRET, now=NOW + timedelta(minutes=11))
    code = await auth.request_code(pool, "c@d.co", secret=SECRET, now=NOW)
    for _ in range(5):
        with pytest.raises(auth.AuthError):
            await auth.verify_code(pool, "c@d.co", "x", secret=SECRET, now=NOW)
    with pytest.raises(auth.AuthError, match="太多次"):
        await auth.verify_code(pool, "c@d.co", code, secret=SECRET, now=NOW)
    with pytest.raises(auth.AuthError, match="格式"):
        await auth.request_code(pool, "not-an-email", secret=SECRET, now=NOW)


async def test_sessions_and_apple(pool):
    acc = await auth.apple_login(pool, "apple-sub-1", "x@privaterelay.appleid.com")
    assert await auth.apple_login(pool, "apple-sub-1") == acc
    token = await auth.new_session(pool, acc, secret=SECRET, now=NOW)
    assert await auth.account_for(pool, token, secret=SECRET, now=NOW) == acc
    assert await auth.account_for(pool, "forged", secret=SECRET, now=NOW) is None
    await auth.logout(pool, token, secret=SECRET)
    assert await auth.account_for(pool, token, secret=SECRET, now=NOW) is None


async def test_keyring_is_encrypted_and_scoped(pool):
    box = auth.KeyBox(Fernet.generate_key())
    a, b = await auth.new_account(pool), await auth.new_account(pool)
    kid = await auth.add_key(pool, box, a, provider="deepseek", api_key="sk-abcdefgh1234", chat_model="deepseek-flash")
    raw = await pool.fetchval("SELECT secret FROM keyring WHERE id = $1", kid)
    assert b"sk-abcdefgh1234" not in bytes(raw) and box.unlock(raw) == "sk-abcdefgh1234"          # 存的是密文
    assert [(k.provider, k.last4) for k in await auth.list_keys(pool, a)] == [("deepseek", "1234")]
    assert await pool.fetchval("SELECT plan FROM accounts WHERE id = $1", a) == "byok"
    comp_a = (await accounts.list_companions(pool, a))[0]
    with pytest.raises(auth.AuthError):
        await auth.use_key(pool, b, (await accounts.list_companions(pool, b))[0], kid)             # 别人的钥匙用不了
    await auth.use_key(pool, a, comp_a, kid)
    keys = auth.DbKeys(pool, box, None)
    conv = (await accounts.list_conversations(pool, a, comp_a))[0].id
    r = await keys.route_for_scope(Scope(a, comp_a, conv))
    assert r.api_key == "sk-abcdefgh1234" and r.chat_model == "deepseek-flash" and not r.trial
    assert await auth.delete_key(pool, b, kid) is False and await auth.delete_key(pool, a, kid) is True


async def test_trial_counts_down_then_says_so(pool):
    box = auth.KeyBox(Fernet.generate_key())
    acc = await auth.new_account(pool)
    comp = (await accounts.list_companions(pool, acc))[0]
    conv = (await accounts.list_conversations(pool, acc, comp))[0].id
    # 额度 0.04 美元、今天不会再补；每轮 10 万输入 token × Flash 0.30/百万 = 0.03 美元
    await pool.execute("UPDATE accounts SET trial_micro = 40000, trial_day = '2999-01-01' WHERE id = $1", acc)
    trial = Route("fake", "ours", "deepseek-flash", "deepseek-flash", trial=True)
    m = FakeModel([{"text": "在的", "usage": Usage(input=100_000)}, {"text": "嗯嗯", "usage": Usage(input=100_000)}])

    async def nosleep(_):
        return None
    d = Deps(pool=pool, embedder=FakeEmbedder(), keys=auth.DbKeys(pool, box, trial), adapter_for=lambda r: m,
             now=lambda: NOW, sleep=nosleep)
    ev = []

    async def emit(e):
        ev.append(e)
    for text in ("在吗", "好累", "还在吗"):
        await run_turn(d, Scope(acc, comp, conv), text, emit)
    assert await pool.fetchval("SELECT trial_micro FROM accounts WHERE id = $1", acc) == 0
    over = [e for e in ev if e["type"] == "error"]
    assert len(over) == 1 and over[0]["kind"] == "trial_over" and "都还在" in over[0]["message"]


async def test_one_trial_per_phone(pool):
    a, b = await auth.new_account(pool), await auth.new_account(pool)
    assert await auth.claim_trial_device(pool, a, "device-1", secret=SECRET) is True
    assert await auth.claim_trial_device(pool, a, "device-1", secret=SECRET) is True           # 自己再来没事
    assert await auth.claim_trial_device(pool, b, "device-1", secret=SECRET) is False
    assert await pool.fetchval("SELECT trial_left FROM accounts WHERE id = $1", b) == 0
