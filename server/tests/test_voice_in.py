"""TA 发语音条（10-03）：量语速停顿事件、基线前后两种措辞、按秒扣额度、转写失败照常、接口进等候区、它看得到〔语音〕。小满。"""
from uuid import UUID

from brain import voice as V
from brain import voice_in as VI
from llm.tts import FakeTTS
from test_api import Env


def _words(text_chunks, gaps, events=()):
    out, t = [], 0.0
    for i, w in enumerate(text_chunks):
        out.append({"text": w, "type": "word", "start": t, "end": t + 0.5})
        t += 0.5 + (gaps[i] if i < len(gaps) else 0)
    for e in events:
        out.append({"text": e, "type": "audio_event", "start": t, "end": t + 0.5})
    return out


def test_measure_and_describe_without_baseline():
    m = VI.measure(_words(["今天", "真的", "好累"], [1.0, 1.2], ["(sighs)", "(laughter)"]), 5)
    assert m.pauses == 2 and m.longest == 1.2 and m.units == 6
    assert m.rate < 3
    note = VI.describe(m, [], "zh")
    assert note.startswith("〔语音 5 秒：") and "说得偏慢" in note and "叹了口气" in note and "笑了一下" in note
    assert "比你平时" not in note
    plain = VI.describe(VI.measure(_words(["你好", "今天", "怎么", "样呀"], []), 2), [], "zh")
    assert plain == "〔语音 2 秒〕"


def test_describe_against_own_baseline():
    base = [{"rate": 5.0, "pause_per_min": 2.0}] * 6
    slow = VI.Measure(seconds=10, units=30, rate=3.5, pauses=6, longest=1.5, events=[])
    note = VI.describe(slow, base, "zh")
    assert "比你平时慢不少" in note and "比平时多" in note
    assert "比你平时" not in VI.describe(slow, base[:4], "zh")                       # 攒不够 5 条不说「比你平时」


async def _env(pool, tmp_path, fake=None):
    e = Env(pool, ["嗯，抱抱你"])
    fake = fake or FakeTTS()
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = (lambda k: fake), "srv", tmp_path
    e.app.state.api.cfg.files_dir = tmp_path
    return e, fake


async def test_voice_message_end_to_end(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        r = await c.post(f"/conversations/{conv['id']}/voice", data={"seconds": "3"},
                         files={"audio": ("v.m4a", b"fake-m4a-bytes", "audio/mp4")})
        assert r.status_code == 201
        got = r.json()
        assert got["text"] == "今天好累" and got["attachment"]["kind"] == "voice"
        q = (await c.get("/voice/quota")).json()
        assert q["chars_left"] == V.FREE_CHARS - 3                                        # 1 秒 1 字
        await c.post(f"/conversations/{conv['id']}/messages",
                     json={"text": got["text"], "attachments": [got["attachment"]["id"]]})
        await e.rooms.idle(UUID(conv["id"]))
        sent = e.model.requests[-1].messages[-1].text
        assert "今天好累" in sent and "〔语音 3 秒" in sent and "叹了口气" in sent
        hist = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        mine = [m for m in hist if m["role"] == "user"][0]
        assert mine["attachments"][0]["kind"] == "voice"
        audio = await c.get(f"/attachments/{got['attachment']['id']}")
        assert audio.content == b"fake-m4a-bytes"


async def test_transcribe_failure_and_quota(pool, tmp_path):
    e, fake = await _env(pool, tmp_path, FakeTTS(fail="server"))
    t = await e.login()
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        r = await c.post(f"/conversations/{conv['id']}/voice", data={"seconds": "4"},
                         files={"audio": ("v.m4a", b"x", "audio/mp4")})
        assert r.status_code == 201 and r.json()["text"] == "（语音没转出文字）"
        acc = await pool.fetchval("SELECT account_id FROM conversations WHERE id = $1", UUID(conv["id"]))
        await pool.execute("UPDATE voice_quota SET chars_left = 2 WHERE account_id = $1", acc)
        r = await c.post(f"/conversations/{conv['id']}/voice", data={"seconds": "10"},
                         files={"audio": ("v.m4a", b"x", "audio/mp4")})
        assert r.status_code == 402
