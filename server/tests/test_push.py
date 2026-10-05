"""推送真发（iOS 第三块第 2 步）：没人在看这个窗口时它回的话排进推送队列；发给账号所有设备；410 删设备；JWT 的样子。测试用小满。"""
import base64
import json
from uuid import UUID

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from push.apns import ApnsConfig, make_jwt, send_pending
from test_api import Env


def cfg():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return ApnsConfig(pem, "KEY123", "TEAM456", "com.lingxi.companion")


def test_jwt_shape_and_reuse():
    c = cfg()
    t = make_jwt(c, 1000.0)
    head, claims, sig = t.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)       # noqa: E731
    assert json.loads(base64.urlsafe_b64decode(pad(head))) == {"alg": "ES256", "kid": "KEY123"}
    assert json.loads(base64.urlsafe_b64decode(pad(claims))) == {"iss": "TEAM456", "iat": 1000}
    assert len(base64.urlsafe_b64decode(pad(sig))) == 64
    assert make_jwt(c, 1000.0 + 60) == t and make_jwt(c, 1000.0 + 3600) != t


async def test_unwatched_reply_is_queued_and_sent(pool):
    e = Env(pool, ["诶你回来啦\n\n今天怎么样"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post("/me/devices", json={"apns_token": "tok-a"})
        await c.post("/me/devices", json={"apns_token": "tok-dead"})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我回来了"})
        await e.rooms.idle(UUID(conv["id"]))                # 没人连事件流 = 没人在看
    assert await pool.fetchval("SELECT text FROM push_queue WHERE conversation_id = $1", UUID(conv["id"])) \
        == "诶你回来啦\n\n今天怎么样"
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return (410, "Unregistered") if url.endswith("tok-dead") else (200, "")
    import push.apns as A
    A.GAP = 0
    assert await send_pending(pool, cfg(), transport) == 1
    # 两条气泡各推一条：第一条两台都试（死的那台删掉），第二条只剩活的那台
    assert [u.rsplit("/", 1)[1] for u, _, _ in sent] == ["tok-a", "tok-dead", "tok-a"]
    _, headers, body = sent[0]
    assert headers["apns-topic"] == "com.lingxi.companion" and headers["authorization"].startswith("bearer ")
    assert body["aps"]["alert"] == {"title": "Lumi", "body": "诶你回来啦"} and body["conversation"] == conv["id"]
    assert sent[2][2]["aps"]["alert"]["body"] == "今天怎么样"
    assert await pool.fetchval("SELECT count(*) FROM devices") == 1                  # 死掉的那台删了
    assert await send_pending(pool, cfg(), transport) == 0                            # 发过的不再发
    await pool.execute("INSERT INTO push_queue (account_id, companion_id, conversation_id, text, created_at) "
                       "SELECT account_id, companion_id, conversation_id, '昨天的话', now() - interval '2 hours' "
                       "FROM push_queue LIMIT 1")
    assert await send_pending(pool, cfg(), transport) == 0                            # 排太久的不推


async def test_watched_reply_is_not_queued(pool):
    e = Env(pool, ["在呢"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        q = e.rooms.listen(UUID(conv["id"]))                # 聊天页开着
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "在吗"})
        await e.rooms.idle(UUID(conv["id"]))
        e.rooms.unlisten(UUID(conv["id"]), q)
    assert await pool.fetchval("SELECT count(*) FROM push_queue") == 0


async def _send_all(pool):
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return 200, ""
    import push.apns as A
    A.GAP = 0
    await send_pending(pool, cfg(), transport)
    return sent


def test_urgent_only_for_their_own_clocks_and_the_day_itself():
    from patrol.wake import urgent
    assert urgent("user", {}) and urgent("date", {"phase": "day"})
    assert not any([urgent("date", {"phase": "eve"}), urgent("date", {"phase": "after"}), urgent("self", {}),
                    urgent("heartbeat", {}), urgent("meal", {}), urgent("picks", {})])


async def test_urgent_push_is_time_sensitive(pool):
    from patrol import store
    e = Env(pool, [])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.post("/me/devices", json={"apns_token": "tok-a"})
        me = UUID((await c.get("/me")).json()["id"])
    await store.queue_push(pool, account=me, companion=UUID(comp["id"]), conversation=UUID(conv["id"]), text="该出门了", urgent=True)
    await store.queue_push(pool, account=me, companion=UUID(comp["id"]), conversation=UUID(conv["id"]), text="在干嘛")
    sent = []

    async def transport(url, headers, body):
        sent.append(json.loads(body))
        return 200, ""
    assert await send_pending(pool, cfg(), transport) == 2
    assert sent[0]["aps"]["interruption-level"] == "time-sensitive" and "interruption-level" not in sent[1]["aps"]


# ── Mele Host 推送中转（10-04 第四步）：内容加密交给中转站，中转站看不见说了什么 ──

async def test_relay_device_gets_sealed_push(pool):
    import os
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    key = AESGCM.generate_key(bit_length=256)
    e = Env(pool, ["晚安小满"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        r = await c.post("/me/devices", json={"apns_token": "relay:abc123", "relay_secret": "s3cret",
                                              "push_key": base64.b64encode(key).decode()})
        assert r.status_code == 204
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我睡了"})
        await e.rooms.idle(UUID(conv["id"]))
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return 200, ""
    import push.apns as A
    A.GAP = 0
    assert await send_pending(pool, None, transport, relay_url="https://relay.test") == 1
    url, headers, body = sent[0]
    assert url == "https://relay.test/push" and headers["authorization"] == "Bearer s3cret"
    assert body["relay_id"] == "abc123" and "晚安" not in json.dumps(body, ensure_ascii=False)   # 中转看不见
    raw = base64.b64decode(body["sealed"])
    inner = json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], None))
    assert inner["aps"]["alert"] == {"title": "Lumi", "body": "晚安小满"} and inner["conversation"] == conv["id"]
    assert body["sound"] is True and body["urgent"] is False


async def test_relay_gone_deletes_device_and_no_apns_without_cfg(pool):
    e = Env(pool, ["在吗"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post("/me/devices", json={"apns_token": "relay:gone", "relay_secret": "x",
                                          "push_key": base64.b64encode(b"k" * 32).decode()})
        await c.post("/me/devices", json={"apns_token": "direct-tok"})     # Host 没有苹果钥匙：直连的那台跳过
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "hi"})
        await e.rooms.idle(UUID(conv["id"]))
    sent = []

    async def transport(url, headers, body):
        sent.append(url)
        return 410, "Unregistered"
    assert await send_pending(pool, None, transport, relay_url="https://relay.test") == 1
    assert sent == ["https://relay.test/push"]
    assert await pool.fetchval("SELECT count(*) FROM devices WHERE apns_token = 'relay:gone'") == 0
