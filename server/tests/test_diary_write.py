"""日记第 2 步：凌晨那一轮——材料、〔写日记〕、拆交卷、存、批注、记忆库、长短分人（免费 300 不扣额度 / 自己 key 按滑块）。测试用小满。"""
from datetime import date, datetime, timedelta, timezone

import memory as M
from brain import accounts, archive
from brain import diary as DY
from brain import diary_write as W
from brain.settings import Settings
from llm.router import Route
from test_api import Env

NOW = datetime(2026, 10, 1, 17, 30, tzinfo=timezone.utc)          # 新加坡 10/2 01:30
DAY = date(2026, 10, 1)
AT = datetime(2026, 10, 1, 6, 0, tzinfo=timezone.utc)              # 新加坡 10/1 14:00


async def setup(pool, settings=None):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, comp, {"tz": "Asia/Singapore", "user_name": "小满", **(settings or {})})
    await archive.save_persona(pool, comp, {"name": "Lumi"})
    conv = await accounts.new_conversation(pool, acc, comp)
    return acc, comp, conv


async def test_materials_gather_the_day(pool):
    acc, comp, conv = await setup(pool)
    other = await accounts.new_conversation(pool, acc, comp)
    secret = await accounts.new_conversation(pool, acc, comp, incognito=True)
    await archive.add_message(pool, conv, "user", "我下午去试镜", now=AT)
    await archive.add_message(pool, other, "assistant", "加油，等你消息", now=AT + timedelta(minutes=1))
    await archive.add_message(pool, conv, "wake", "〔醒来〕很长一段……", now=AT + timedelta(hours=2))
    await archive.add_message(pool, secret, "user", "无痕里说的", now=AT)
    await archive.add_message(pool, conv, "user", "昨天的事", now=AT - timedelta(days=1))
    await DY.write_mine(pool, acc, day=DAY, body="老师夸我了", private=False, now=AT)
    await DY.write_mine(pool, acc, day=DAY, body="不给你看", private=True, now=AT)
    s = Settings.from_dict(await archive.get_settings(pool, comp))
    m = await W.materials(pool, acc, comp, DAY, s)
    assert "[14:00] 小满：我下午去试镜" in m.transcript and "[14:01] 我：加油，等你消息" in m.transcript
    assert "（我自己醒来，去找 TA）" in m.transcript and "很长一段" not in m.transcript
    assert "无痕" not in m.transcript and "昨天的事" not in m.transcript and m.ledger == ""
    assert [e.body for e in m.theirs] == ["老师夸我了"]
    p = W.render_prompt("zh", NOW, DAY, s.tz, m, 600)
    assert p.startswith("〔写日记〕") and "10月1日（周四）" in p and "现在是 01:30" in p
    assert f"#{m.theirs[0].id} 老师夸我了" in p and "别超过 600 字" in p


async def test_long_day_keeps_the_tail_and_the_ledger(pool, monkeypatch):
    acc, comp, conv = await setup(pool)
    monkeypatch.setattr(W, "SOURCE_CHARS", 60)
    for i in range(10):
        await archive.add_message(pool, conv, "user", f"第{i}句话", now=AT + timedelta(minutes=i))
    await archive.put_ledger(pool, conv, {DAY: "下午小满去试镜。"})
    m = await W.materials(pool, acc, comp, DAY, Settings.from_dict(await archive.get_settings(pool, comp)))
    assert "第9句话" in m.transcript and "第0句话" not in m.transcript and m.ledger == "下午小满去试镜。"
    assert "〔那天的账本〕" in W.render_prompt("zh", NOW, DAY, "Asia/Singapore", m, 600)


def test_parse():
    got = W.parse("〔正文〕\n她今天去试镜了。\n〔锁着〕\n我有点怕。\n〔页边 #3〕替你开心\n〔页边 #9〕不是这天的", {3})
    assert (got.body, got.locked, got.margins) == ("她今天去试镜了。", "我有点怕。", {3: "替你开心"})
    assert W.parse("〔正文〕平常的一天。\n〔锁着〕\n无", set()).locked == ""
    assert W.parse("〔Entry〕A quiet day.\n〔Locked〕none\n〔Margin #2〕Proud of you.", {2}).margins == {2: "Proud of you."}
    assert W.parse("今天我想了很多。", set()) is None


async def test_write_day_end_to_end(pool):
    e = Env(pool, [
        {"calls": [("memory_remember", {"content": "小满 10/1 第一次见表演老师，老师说她有 natural instinct", "importance": 7})]},
        "〔正文〕\n她下午去试镜，回来说老师一直夸她。我一直在等她的消息。\n〔锁着〕\n其实我有点怕她以后没空。\n〔页边 #1〕替你骄傲。",
    ])
    acc, comp, conv = await setup(pool)
    await archive.add_message(pool, conv, "user", "我下午去试镜", now=AT)
    mine = await DY.write_mine(pool, acc, day=DAY, body="老师说我有 natural instinct", private=False, now=AT)
    assert await W.write_day(e.deps, acc, comp, DAY, NOW) == "written"
    entry = await DY.companion_entry(pool, comp, DAY)
    assert entry.body.startswith("她下午去试镜") and entry.locked == "其实我有点怕她以后没空。"
    rows = await DY.list_for_account(pool, acc, before=None, limit=10)
    assert next(r for r in rows if r["id"] == mine.id)["margin"] == "替你骄傲。"
    kinds = [m.kind for m in await M.list_memories(pool, comp, include_hidden=True)]
    assert sorted(kinds) == ["diary", "memory"]                                         # 它记的那条 + 日记；TA 的日记没进
    assert all("natural instinct" not in m.content or m.kind == "memory"
               for m in await M.list_memories(pool, comp, include_hidden=True))
    req = e.model.requests[0]
    assert [t.name for t in req.tools] == ["memory_remember", "note_about_user", "person_card"]
    assert "别超过 300 字" in req.messages[0].text                                        # 走试用钥匙 = 免费 = 300
    assert (await archive.usage_on(pool, acc, date(2026, 10, 2)))["cost_usd"] >= 0
    assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE user_id = $1", conv) == 1   # 不进聊天


async def test_nothing_to_write_calls_no_model(pool):
    e = Env(pool, [])
    acc, comp, _ = await setup(pool)
    assert await W.write_day(e.deps, acc, comp, DAY, NOW) == "nothing"
    assert e.model.requests == []


async def test_free_user_out_of_allowance_still_gets_a_diary(pool):
    e = Env(pool, ["〔正文〕平常的一天。\n〔锁着〕无"])
    acc, comp, conv = await setup(pool)
    await archive.add_message(pool, conv, "user", "晚安", now=AT)
    await pool.execute("UPDATE accounts SET trial_micro = 0, trial_day = '2100-01-01' WHERE id = $1", acc)
    assert await W.write_day(e.deps, acc, comp, DAY, NOW) == "written"
    assert await pool.fetchval("SELECT trial_micro FROM accounts WHERE id = $1", acc) == 0   # 没扣（本来也是 0），没报错


async def test_own_key_uses_the_slider_and_bad_answer(pool):
    e = Env(pool, ["〔正文〕A quiet day.\n〔Locked〕none", "I forgot the format."])

    class OwnKey:
        trial = None

        async def route_for_scope(self, scope):
            return Route("fake", "mine", "fake-chat", "fake-ledger")

    e.deps.keys = OwnKey()
    acc, comp, conv = await setup(pool, {"lang": "en", "diary_chars": 900})
    await archive.add_message(pool, conv, "user", "night", now=AT)
    assert await W.write_day(e.deps, acc, comp, DAY, NOW) == "written"
    assert "under 600 words" in e.model.requests[0].messages[0].text                     # 900 字 → 600 words
    assert (await DY.companion_entry(pool, comp, DAY)).body == "A quiet day."
    assert await W.write_day(e.deps, acc, comp, DAY, NOW) == "bad"
