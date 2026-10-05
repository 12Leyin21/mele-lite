"""总单子 13 b / c（10-01 Tilia）：Claude + 中文用户用英文想、思考链能翻成中文（翻一次存一份）；自定义角色想事也得是它，出厂 Lumi 不加。"""
from uuid import UUID

from brain.inject import thinking_style
from brain.persona import Persona
from brain.settings import Settings
from llm.router import Route
from test_api import Env


def test_english_and_in_character_lines():
    s = Settings.from_dict({"lang": "zh", "user_pronoun": "she", "user_name": "小满"})
    zh = thinking_style(s)
    assert "我用中文想" in zh and "想事的时候我也是" not in zh
    en = thinking_style(s, english=True)
    assert "I think in English" in en and "She is 小满" in en
    assert "想事的时候我也是林晚：用林晚的性格" in thinking_style(s, character="林晚")
    assert "When I think, I'm still 林晚" in thinking_style(s, english=True, character="林晚")
    assert not Persona.from_dict({"name": "小宝"}, "zh").custom("zh")              # 只改名字 = 还是出厂的
    assert Persona.from_dict({"personality": "冷淡毒舌"}, "zh").custom("zh")
    assert Persona.from_dict({"imported": "林晚，书店老板"}, "zh").custom("zh")


async def test_claude_thinks_in_english_and_translates(pool):
    e = Env(pool, [{"thinking": "She just told me about the audition and I can't stop smiling.", "text": "真的吗！"},
                   "她刚跟我说了试镜，我一直在笑。"])
    e.deps.keys.trial = Route("anthropic", "ours", "fake-chat", "fake-ledger", trial=True)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "user_name": "小满",
                                                                         "thinking_mode": "native"}})   # 测原生思考那条路
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我今天去试镜了"})
        await e.rooms.idle(UUID(conv["id"]))
        ask = e.model.requests[0].messages[-1].text
        assert "I think in English" in ask and "〔用中文想〕" not in ask
        mid = await pool.fetchval("SELECT id FROM chat_messages WHERE role = 'assistant'")
        r = await c.post(f"/messages/{mid}/thinking/translate")
        assert r.json() == {"text": "她刚跟我说了试镜，我一直在笑。"}
        assert "内心独白" in e.model.requests[1].messages[0].text and e.model.requests[1].model == "fake-ledger"
        r = await c.post(f"/messages/{mid}/thinking/translate")
        assert r.json()["text"].startswith("她刚") and len(e.model.requests) == 2              # 翻过的不再花钱
        user_mid = await pool.fetchval("SELECT id FROM chat_messages WHERE role = 'user'")
        assert (await c.post(f"/messages/{user_mid}/thinking/translate")).status_code == 400
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.post(f"/messages/{mid}/thinking/translate")).status_code == 404
