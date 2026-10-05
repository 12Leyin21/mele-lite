"""声音（10-03）：标记和标签、额度、缓存、自带 key、没钥匙。假接头，不联网。测试用小满。"""
from uuid import UUID

import pytest

from brain import auth, voice as V
from llm.tts import FakeTTS
from test_api import Env


def test_marks_and_tags():
    b = "🎤 [low and close, unhurried] 晚安…\n[quiet laugh] 明天见"
    assert V.is_voice(b) and not V.is_voice("晚安")
    assert V.body(b).startswith("[low and close")
    assert V.as_text(b) == "晚安…\n明天见"
    assert V.fingerprint("a", "v", "m") != V.fingerprint("a", "v2", "m")


async def _setup(pool, tmp_path, *, server_key="srv", fake=None, email="xiaoman@example.com"):
    e = Env(pool, [""])
    fake = fake or FakeTTS()
    keys_seen = []

    def tts_for(k):
        keys_seen.append(k)
        return fake
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = tts_for, server_key, tmp_path
    t = await e.login(email)
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
    acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", UUID(comp["id"]))
    return e, acc, fake, keys_seen


async def test_quota_cache_and_usage(pool, tmp_path):
    e, acc, fake, keys = await _setup(pool, tmp_path)
    assert await V.quota(pool, acc) == V.FREE_CHARS
    c1 = await V.speak(e.deps, acc, text="[softly] 晚安", voice_id="v1", purpose="note")
    assert not c1.cached and (tmp_path / "voice" / f"{c1.id}.mp3").read_bytes().startswith(b"ID3fake")
    assert await V.quota(pool, acc) == V.FREE_CHARS - len("[softly] 晚安") and keys == ["srv"]
    again = await V.speak(e.deps, acc, text="[softly] 晚安", voice_id="v1", purpose="speak")
    assert again.cached and again.id == c1.id and len(fake.calls) == 1             # 念过的不再花钱
    assert await V.quota(pool, acc) == V.FREE_CHARS - len("[softly] 晚安")
    await pool.execute("UPDATE voice_quota SET chars_left = 3 WHERE account_id = $1", acc)
    with pytest.raises(V.VoiceError) as err:
        await V.speak(e.deps, acc, text="这句太长了念不起", voice_id="v1", purpose="note")
    assert err.value.kind == "quota"
    row = await pool.fetchrow("SELECT purpose, chars, own_key, cost_usd FROM voice_usage WHERE account_id = $1", acc)
    assert row["purpose"] == "note" and not row["own_key"] and row["cost_usd"] > 0
    await V.attach(pool, acc, [c1.id], 42)
    got = await V.clips_for_message(pool, acc, 42)
    assert got[V.text_sha("[softly] 晚安")].id == c1.id


async def test_own_key_not_charged_and_no_key(pool, tmp_path):
    e, acc, fake, keys = await _setup(pool, tmp_path)
    await auth.add_voice_key(pool, e.deps.keys.box, acc, "sk_mine_12345678")
    await auth.add_voice_key(pool, e.deps.keys.box, acc, "sk_mine_87654321")        # 新的顶掉旧的
    assert await pool.fetchval("SELECT count(*) FROM keyring WHERE provider = 'elevenlabs'") == 1
    await V.speak(e.deps, acc, text="早", voice_id="v1", purpose="note")
    assert keys == ["sk_mine_87654321"] and await V.quota(pool, acc) == V.FREE_CHARS
    assert await pool.fetchval("SELECT own_key FROM voice_usage") is True
    kid = await pool.fetchval("SELECT id FROM keyring WHERE provider = 'elevenlabs'")
    comp = await pool.fetchval("SELECT id FROM companions WHERE account_id = $1", acc)
    with pytest.raises(auth.AuthError):                                             # 声音 key 不能当聊天钥匙
        await auth.use_key(pool, acc, comp, kid)

    e2, acc2, _, _ = await _setup(pool, tmp_path, server_key="", email="mia@example.com")
    with pytest.raises(V.VoiceError) as err:
        await V.speak(e2.deps, acc2, text="早", voice_id="v1", purpose="note")
    assert err.value.kind == "no_key"


async def test_tts_error_and_no_voice(pool, tmp_path):
    e, acc, _, _ = await _setup(pool, tmp_path, fake=FakeTTS(fail="server"))
    with pytest.raises(V.VoiceError) as err:
        await V.speak(e.deps, acc, text="早", voice_id="v1", purpose="note")
    assert err.value.kind == "server" and await V.quota(pool, acc) == V.FREE_CHARS   # 没念成不扣
    ok = FakeTTS()
    e.deps.tts_for = lambda k: ok
    await V.speak(e.deps, acc, text="早", voice_id="", purpose="note")                # 没选嗓子 = 出厂那把 Hope
    assert ok.calls[0][2] == V.PRESETS[0]["voice_id"]
