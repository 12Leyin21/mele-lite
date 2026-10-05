"""Mele Host 单人模式（10-04）：配对码换登录凭证、/version、Host 模式下关掉邮箱登录。测试数据用小满。"""
from datetime import datetime, timezone

import httpx
import pytest
from cryptography.fernet import Fernet

from api.app import API_VERSION, create_app
from api.deps import ApiConfig
from brain import auth, host
from brain.turn import Deps
from llm.fake import FakeModel
from memory.embed import FakeEmbedder

SECRET = "test-secret"
NOW = datetime(2026, 10, 5, 1, 0, tzinfo=timezone.utc)


def make_app(pool, *, host_mode: bool):
    box = auth.KeyBox(Fernet.generate_key())
    deps = Deps(pool=pool, embedder=FakeEmbedder(), keys=auth.DbKeys(pool, box, None),
                adapter_for=lambda r: FakeModel([]))
    return create_app(deps, ApiConfig(secret=SECRET, box=box, host_mode=host_mode))


def client(app, token=None):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test", headers=headers)


async def test_version_says_host(pool):
    async with client(make_app(pool, host_mode=True)) as c:
        r = await c.get("/version")
    assert r.status_code == 200
    assert r.json() == {"api": API_VERSION, "host": True}


async def test_version_not_host(pool):
    async with client(make_app(pool, host_mode=False)) as c:
        assert (await c.get("/version")).json()["host"] is False


async def test_host_mode_has_no_email_login(pool):
    async with client(make_app(pool, host_mode=True)) as c:
        assert (await c.post("/auth/email/code", json={"email": "xiaoman@example.com"})).status_code == 404
        assert (await c.post("/auth/email/verify", json={"email": "xiaoman@example.com", "code": "123456"})).status_code == 404


# ── 配对码 ──


def test_normalize_ignores_spaces_dashes_case():
    assert host.normalize(" ab3d-ef7h ") == "AB3DEF7H"


async def test_new_code_shape_and_only_latest_works(pool):
    first = await host.new_code(pool, secret=SECRET, now=NOW)
    assert len(first) == 9 and first[4] == "-"
    assert not set(first.replace("-", "")) & set("01OI")
    second = await host.new_code(pool, secret=SECRET, now=NOW)
    with pytest.raises(host.PairError):
        await host.pair(pool, first, secret=SECRET, now=NOW)
    acc = await host.pair(pool, second, secret=SECRET, now=NOW)
    assert acc == await host.owner(pool)


async def test_code_is_single_use_and_owner_is_kept(pool):
    code = await host.new_code(pool, secret=SECRET, now=NOW)
    acc = await host.pair(pool, code.lower(), secret=SECRET, now=NOW)
    assert not await host.has_code(pool)
    with pytest.raises(host.PairError):
        await host.pair(pool, code, secret=SECRET, now=NOW)
    again = await host.new_code(pool, secret=SECRET, now=NOW)        # 换手机 / 重新配对：还是同一个主人
    assert await host.pair(pool, again, secret=SECRET, now=NOW) == acc
    assert await pool.fetchval("SELECT count(*) FROM accounts") == 1
    assert await pool.fetchval("SELECT plan FROM accounts WHERE id = $1", acc) == "byok"


async def test_pair_endpoint_gives_token(pool):
    app = make_app(pool, host_mode=True)
    code = await host.new_code(pool, secret=SECRET, now=datetime.now(timezone.utc))
    async with client(app) as c:
        r = await c.post("/host/pair", json={"code": code, "tz": "Asia/Singapore"})
    assert r.status_code == 200
    token = r.json()["token"]
    async with client(app, token) as c:
        me = await c.get("/me")
        assert me.status_code == 200 and "trial" not in me.json()             # Host 没有试用额度
        comps = (await c.get("/companions")).json()
    assert len(comps) == 1                                           # 送的那个 Lumi


async def test_pair_endpoint_wrong_code_and_lockout(pool):
    app = make_app(pool, host_mode=True)
    code = await host.new_code(pool, secret=SECRET, now=datetime.now(timezone.utc))
    async with client(app) as c:
        for _ in range(5):
            assert (await c.post("/host/pair", json={"code": "AAAA-AAAA"})).status_code == 400
        assert (await c.post("/host/pair", json={"code": code})).status_code == 429   # 连错 5 次先锁 10 分钟


async def test_pair_endpoint_404_when_not_host(pool):
    async with client(make_app(pool, host_mode=False)) as c:
        assert (await c.post("/host/pair", json={"code": "AAAA-AAAA"})).status_code == 404


# ── 起服务的开关、命令行 ──

from api import host as host_cli  # noqa: E402


def test_flags_defaults_off():
    f = host_cli.flags({})
    assert (f.host, f.rerank, f.public_url) == (False, False, "")


def test_flags_host_on_rerank_follows_env():
    f = host_cli.flags({"NEWAPP_HOST": "1", "NEWAPP_PUBLIC_URL": "https://1-2-3-4.sslip.io/"})
    assert f.host and not f.rerank and f.public_url == "https://1-2-3-4.sslip.io"
    assert host_cli.flags({"NEWAPP_HOST": "1", "NEWAPP_RERANK": "1"}).rerank


def test_rerank_only_when_asked():
    assert host_cli.flags({}).rerank is False
    assert host_cli.flags({"NEWAPP_HOST": "0"}).rerank is False
    assert host_cli.flags({"NEWAPP_RERANK": "1"}).rerank is True


def test_pairing_link():
    assert host_cli.pairing_link("https://1-2-3-4.sslip.io", "AB3D-EF7H") == \
        "mele://host?u=https%3A%2F%2F1-2-3-4.sslip.io&c=AB3D-EF7H"


async def test_ensure_code_only_when_nobody_paired(pool):
    assert await host_cli.ensure_code(pool, secret=SECRET) is not None       # 新服务器：出一张
    assert await host_cli.ensure_code(pool, secret=SECRET) is None           # 有没用的码了：不再出
    code = await host.new_code(pool, secret=SECRET, now=NOW)
    await host.pair(pool, code, secret=SECRET, now=NOW)
    assert await host_cli.ensure_code(pool, secret=SECRET) is None           # 有主人了：重启不出新码
