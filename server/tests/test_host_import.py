"""Mele Host 搬家（10-04 第三步）：Lite 手机里的东西一次性整包搬上 Host。测试数据用小满 / Mia。"""
import base64
import io
from datetime import datetime, timezone
from uuid import UUID

import pytest
from cryptography.fernet import Fernet

from brain import accounts, archive, auth, host_import

NOW = datetime(2026, 10, 5, 1, 0, tzinfo=timezone.utc)
CID = "6b1f0c3e-1111-4a2b-9c3d-000000000001"
CONV = "6b1f0c3e-2222-4a2b-9c3d-000000000002"
def _png() -> str:
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (4, 4), (200, 120, 160)).save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode()


PNG = _png()


def bundle(**over):
    b = {
        "version": 1,
        "profile": {"name": "小满", "pronoun": "she"},
        "keys": [{"local_id": "k1", "provider": "deepseek", "chat_model": "deepseek-flash", "api_key": "sk-test-0000000001234"}],
        "companions": [{
            "id": CID, "persona": {"name": "Mia", "about": "温柔"}, "settings": {"voice_mode": "often", "not_a_setting": 1},
            "key_local_id": "k1", "avatar_b64": PNG,
            "conversations": [{"id": CONV, "messages": [
                {"role": "user", "text": "早", "at": "2026-10-01T00:00:00Z"},
                {"role": "assistant", "text": "早呀", "thinking": "她起得早", "at": "2026-10-01T00:00:05Z"},
            ]}],
        }],
    }
    b.update(over)
    return b


@pytest.fixture
def box():
    return auth.KeyBox(Fernet.generate_key())


async def test_import_moves_core(pool, box, tmp_path):
    acc = await auth.new_account(pool)                       # 配对时送的那个空 Lumi
    got = await host_import.run(pool, box, acc, bundle(), files_dir=tmp_path, now=NOW)
    assert got == {"companions": 1, "conversations": 1, "messages": 2, "keys": 1}
    comps = await accounts.list_companions(pool, acc)
    assert [str(c) for c in comps] == [CID]                 # 空的那个 Lumi 让位
    assert (await archive.get_persona(pool, comps[0]))["name"] == "Mia"
    s = await archive.get_settings(pool, comps[0])
    assert s["voice_mode"] == "often" and "not_a_setting" not in s
    msgs = await pool.fetch("SELECT role, text, thinking, created_at FROM chat_messages WHERE user_id = $1 ORDER BY id", UUID(CONV))
    assert [(m["role"], m["text"]) for m in msgs] == [("user", "早"), ("assistant", "早呀")]
    assert msgs[1]["thinking"] == "她起得早"
    assert msgs[0]["created_at"] == datetime(2026, 10, 1, tzinfo=timezone.utc)   # 按原来的时间
    key = await pool.fetchrow("SELECT provider, secret, last4 FROM keyring WHERE account_id = $1", acc)
    assert key["provider"] == "deepseek" and key["last4"] == "1234" and box.unlock(key["secret"]) == "sk-test-0000000001234"
    bound = await pool.fetchval("SELECT key_id FROM companions WHERE id = $1", comps[0])
    assert bound is not None
    assert (tmp_path / "avatars" / f"{CID}.jpg").exists()
    prof = await accounts.get_profile(pool, acc)
    assert prof["name"] == "小满"


async def test_import_keeps_companion_that_has_chats(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    lumi = (await accounts.list_companions(pool, acc))[0]
    conv = (await accounts.list_conversations(pool, acc, lumi))[0]
    await archive.add_message(pool, conv.id, "user", "在 Host 上已经聊过了", now=NOW)
    await host_import.run(pool, box, acc, bundle(), files_dir=tmp_path, now=NOW)
    assert len(await accounts.list_companions(pool, acc)) == 2


async def test_import_twice_does_not_duplicate(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    await host_import.run(pool, box, acc, bundle(), files_dir=tmp_path, now=NOW)
    again = await host_import.run(pool, box, acc, bundle(keys=[]), files_dir=tmp_path, now=NOW)
    assert again["companions"] == 0 and again["messages"] == 0
    assert await pool.fetchval("SELECT count(*) FROM chat_messages") == 2


async def test_import_rejects_unknown_version(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    with pytest.raises(host_import.ImportError_):
        await host_import.run(pool, box, acc, bundle(version=99), files_dir=tmp_path, now=NOW)


async def test_import_endpoint_host_only(pool, tmp_path):
    from tests.test_host import client, make_app
    from brain import host
    for host_mode, want in ((False, 404), (True, 200)):
        app = make_app(pool, host_mode=host_mode)
        app.state.api.cfg.files_dir = tmp_path
        acc = await host.owner(pool) or await auth.new_account(pool)
        token = await auth.new_session(pool, acc, secret="test-secret", now=NOW)
        async with client(app, token) as c:
            r = await c.post("/me/import", json=bundle(keys=[]))
        assert r.status_code == want
    assert r.json()["messages"] == 2
