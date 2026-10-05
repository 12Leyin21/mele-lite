"""声音接口（10-03）：念给我听（缓存、越界、别人的）、取语音、描述一把的门槛、存嗓子（声音位满）、额度、ElevenLabs key。"""
from uuid import UUID

from llm.tts import FakeTTS
from test_api import Env


async def _env(pool, tmp_path, fake=None):
    e = Env(pool, ["今天辛苦啦\n\n明天见"])
    fake = fake or FakeTTS()
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = (lambda k: fake), "srv", tmp_path
    return e, fake


async def test_speak_and_clip(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "voice_id": "v1"}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        mine = [m for m in msgs if m["role"] == "user"][0]
        it = [m for m in msgs if m["role"] == "assistant"][0]
        r = await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert r.status_code == 200 and fake.calls[-1][1] == "[warm, relaxed, natural] 明天见"   # 没写标签的先垫一个
        again = await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert again.json()["id"] == r.json()["id"] and len(fake.calls) == 1
        assert (await c.post(f"/messages/{it['id']}/speak", json={"index": 5})).status_code == 400
        assert (await c.post(f"/messages/{mine['id']}/speak", json={"index": 0})).status_code == 400
        audio = await c.get(f"/voice/clips/{r.json()['id']}")
        assert audio.status_code == 200 and audio.headers["content-type"] == "audio/mpeg"
        q = (await c.get("/voice/quota")).json()
        assert q["chars_left"] == 2000 - len("[warm, relaxed, natural] 明天见") and q["own_key"] is False
    t2 = await e.login("mia@example.com")
    async with e.client(t2) as c2:
        assert (await c2.get(f"/voice/clips/{r.json()['id']}")).status_code == 404
        assert (await c2.post(f"/messages/{it['id']}/speak", json={"index": 0})).status_code == 400


async def test_design_gate_and_choose(pool, tmp_path):
    e, fake = await _env(pool, tmp_path, FakeTTS(slots=(30, 30)))
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        assert (await c.post("/voice/design", json={"description": "低一点、懒洋洋的、带点气声"})).status_code == 403
        ok = await c.post(f"/companions/{comp['id']}/voice", json={"voice_id": "v_preset", "name": "Aria"})
        assert ok.json() == {"voice_id": "v_preset", "voice_name": "Aria"}
        got = (await c.get(f"/companions/{comp['id']}")).json()["settings"]
        assert got["voice_id"] == "v_preset" and got["voice_name"] == "Aria"
        assert (await c.post("/keys/elevenlabs", json={"api_key": "sk_mine_12345678"})).status_code == 201
        prev = await c.post("/voice/design", json={"description": "低一点、懒洋洋的、带点气声"})
        assert prev.status_code == 200 and len(prev.json()) == 3
        full = await c.post(f"/companions/{comp['id']}/voice",
                            json={"generated_voice_id": "g1", "name": "懒懒", "description": "低一点"})
        assert full.status_code == 409                                                   # 声音位满了
        fake._slots = (3, 30)
        saved = await c.post(f"/companions/{comp['id']}/voice",
                             json={"generated_voice_id": "g1", "name": "懒懒", "description": "低一点"})
        assert saved.json()["voice_id"] == "v_g1"
        assert (await c.get("/voice/quota")).json()["own_key"] is True


async def test_presets(pool, tmp_path):
    e, _ = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        ps = (await c.get("/voice/presets")).json()
        assert [p["name"] for p in ps] == ["Lauren", "Hope", "Andrew", "Jon"] and ps[0]["about"] == "温柔、让人安心"
        r = await c.get("/" + ps[0]["preview"], params={"lang": "en"})
        assert r.status_code == 200 and r.headers["content-type"] == "audio/mpeg"
        assert (await c.get("/voice/presets/nope/preview")).status_code == 404
