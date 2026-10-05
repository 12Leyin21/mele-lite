"""语音条在一轮里（10-03）：🎤 那段念出来、事件带 voice、逐字稿去标签；额度不够 / 不发档 / 无痕回落文字；
历史接口 voices 对得上；底子里有档位那句。测试用小满。"""
from uuid import UUID

from brain import voice as V
from brain.bubbles import split_reply
from llm.tts import FakeTTS
from test_api import Env

REPLY = "今天辛苦啦\n\n🎤 [low and close, unhurried] 晚安…早点睡\n\n明天见"


def test_voice_paragraph_is_its_own_bubble():
    assert split_reply(REPLY, 1) == ["今天辛苦啦", "🎤 [low and close, unhurried] 晚安…早点睡", "明天见"]
    long_voice = "🎤 " + "很长的一句话。" * 60
    assert split_reply(long_voice, 6) == [long_voice]


async def _chat(pool, tmp_path, settings=None, fake=None, quota=None):
    e = Env(pool, [REPLY])
    fake = fake or FakeTTS()
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = (lambda k: fake), "srv", tmp_path
    t = await e.login()
    events = []
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "voice_id": "v1", **(settings or {})}})
        acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", UUID(comp["id"]))
        if quota is not None:
            await V.quota(pool, acc)
            await pool.execute("UPDATE voice_quota SET chars_left = $2 WHERE account_id = $1", acc, quota)
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "晚安"})
        await e.rooms.idle(UUID(conv["id"]))
        hist = (await c.get(f"/conversations/{conv['id']}/messages")).json()
    return e, fake, hist, acc


async def test_voice_note_spoken_and_in_history(pool, tmp_path):
    e, fake, hist, acc = await _chat(pool, tmp_path)
    assert fake.calls[0][1] == "[low and close, unhurried] 晚安…早点睡" and fake.calls[0][2] == "v1"
    assert fake.calls[0][4] == "今天辛苦啦" and fake.calls[0][5] == "明天见"          # 前后句递上，语气接得上
    m = [x for x in hist["messages"] if x["role"] == "assistant"][0]
    assert m["bubbles"] == ["今天辛苦啦", "晚安…早点睡", "明天见"]
    assert m["voices"][0] is None and m["voices"][2] is None and m["voices"][1]["id"]
    clip = await pool.fetchrow("SELECT message_id, path FROM voice_clips")
    assert clip["message_id"] == m["id"]
    sys = "".join(b.text for b in e.model.requests[0].system)
    assert "🎤" in sys and "手册 voice" in sys                                          # 偶尔档那句在底子里


async def test_falls_back_to_text(pool, tmp_path):
    _, fake, hist, _ = await _chat(pool, tmp_path, quota=2)
    m = [x for x in hist["messages"] if x["role"] == "assistant"][0]
    assert m["bubbles"] == ["今天辛苦啦", "晚安…早点睡", "明天见"] and m["voices"] == [None, None, None]
    assert "🎤" not in m["text"] and "[low" not in m["text"]                         # 存档里那段也改成文字


async def test_off_mode_never_calls_tts(pool, tmp_path):
    e, fake, hist, _ = await _chat(pool, tmp_path, settings={"voice_mode": "off"})
    assert fake.calls == []
    assert "🎤" not in "".join(b.text for b in e.model.requests[0].system)
    m = [x for x in hist["messages"] if x["role"] == "assistant"][0]
    assert m["bubbles"][1] == "晚安…早点睡"
