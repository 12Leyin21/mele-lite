import random

from brain.inject import TEXTS, TurnFacts, injection_due, reminder_lines, thinking_style
from brain.settings import Injection, Settings


def facts(turn=1, user="你好", last="", tools=()):
    return TurnFacts(turn_no=turn, user_text=user, last_assistant=last, last_tools=list(tools))


def lines(settings, f, seed=0):
    return reminder_lines(settings, f, random.Random(seed))


def test_thinking_style_every_turn_and_override():
    first = lines(Settings(), facts())[0]
    assert first.startswith("〔想事的时候〕\n这里的念头不用好看") and TEXTS["zh"]["think_lang"] not in lines(Settings(), facts())
    s = Settings(thinking_style_text="〔想事〕先想三秒。")
    got = lines(s, facts())
    assert got[0] == "〔想事〕先想三秒。" and TEXTS["zh"]["think_lang"] in got      # 自己写的风格：另贴〔用中文想〕


def test_factory_thinking_style_follows_name_pronoun_and_language():
    t = thinking_style(Settings(user_name="小满", user_pronoun="she"))
    assert "她是小满，是「她」，不是「用户」。我们两个是「我们」，不是「他们」。" in t
    assert "她的头发" in t and "我伸手碰她时" in t and "我用中文想" in t and "{" not in t
    assert "TA是正在跟我说话的人，是「TA」" in thinking_style(Settings())
    t = thinking_style(Settings(lang="en", user_name="Mia", user_pronoun="she"))
    assert 'She is Mia, "she", never "the user". The two of us are "we", never "they".' in t
    assert "her hair" in t and "the face she makes when she says" in t and "I think in English" in t
    t = thinking_style(Settings(lang="en", user_pronoun="he"))
    assert "He is the person I'm talking with" in t and "reach for him" in t and "I think in English" in t
    t = thinking_style(Settings(lang="en"))
    assert '"we".' in t and 'never "they"' not in t and "the face they make when they say" in t


def test_tool_reminder_every_n_turns():
    s = Settings(tool_reminder_every=3)
    assert TEXTS["zh"]["tool_reminder"] in lines(s, facts(turn=3))
    assert TEXTS["zh"]["tool_reminder"] not in lines(s, facts(turn=2))


def test_remembered_fires_only_when_promise_without_tool():
    assert TEXTS["zh"]["remembered"] in lines(Settings(), facts(last="好，记住了～"))          # 出厂开着（09-27 下午改回）
    s = Settings(sentinels={"remembered": True})
    assert TEXTS["zh"]["remembered"] in lines(s, facts(last="好，记住了～"))
    assert TEXTS["zh"]["remembered"] not in lines(s, facts(last="好，记住了～", tools=["memory_remember"]))
    assert TEXTS["zh"]["remembered"] not in lines(s, facts(last="今天天气不错"))
    assert TEXTS["zh"]["remembered"] in lines(s, facts(last="Got it, I'll remember that."))


def test_sentinels_can_be_turned_off():
    s = Settings(sentinels={"thinking_style": False, "tool_reminder": False, "remembered": False},
                 tool_reminder_every=1, thinking=False)
    assert lines(s, facts(last="记住了")) == []


def test_long_mode_line():
    assert TEXTS["zh"]["long_mode"] in lines(Settings(long_mode=True), facts())


def test_injection_modes():
    f = facts(turn=4, user="今晚想吃火锅")
    assert injection_due(Injection("a", "a", "x"), f, random.Random(0))
    assert injection_due(Injection("a", "a", "x", mode="every_n", n=2), f, random.Random(0))
    assert not injection_due(Injection("a", "a", "x", mode="every_n", n=3), f, random.Random(0))
    assert injection_due(Injection("a", "a", "x", mode="chance", chance=0.9), f, random.Random(0))   # 0.844 < 0.9
    assert not injection_due(Injection("a", "a", "x", mode="chance", chance=0.5), f, random.Random(0))
    assert injection_due(Injection("a", "a", "x", mode="keywords", keywords=["火锅"]), f, random.Random(0))
    assert not injection_due(Injection("a", "a", "x", mode="keywords", keywords=["烧烤"]), f, random.Random(0))


def test_disabled_or_empty_injections_skipped_and_order_kept():
    s = Settings(sentinels={"thinking_style": False, "tool_reminder": False, "remembered": False}, thinking=False,
                 injections=[Injection("1", "a", "〔甲〕"), Injection("2", "b", "〔乙〕", enabled=False),
                             Injection("3", "c", "  "), Injection("4", "d", "〔丁〕")])
    assert lines(s, facts()) == ["〔甲〕", "〔丁〕"]


def test_english_texts():
    assert lines(Settings(lang="en"), facts())[0].startswith("〔How I think〕\nThoughts in here")


def test_remembered_counts_note_about_user_too():
    f = facts(last="好，记住了～", tools=["note_about_user"])
    assert TEXTS["zh"]["remembered"] not in lines(Settings(sentinels={"remembered": True}), f)


def test_think_in_chinese_when_thinking_on_and_lang_zh():
    off = {"thinking_style": False, "tool_reminder": False, "remembered": False}
    assert lines(Settings(sentinels=off), facts()) == [TEXTS["zh"]["think_lang"]]      # 哨兵全关也贴：跟着语言走
    assert lines(Settings(sentinels=off, thinking=False), facts()) == []
    assert lines(Settings(sentinels=off, lang="en"), facts()) == []


def test_no_draft_line_only_when_asked():
    assert "想完就说，不在心里打草稿" in thinking_style(Settings(), no_draft=True)
    assert "打草稿" not in thinking_style(Settings())
    assert "no drafting" in thinking_style(Settings(lang="en"), no_draft=True)
    assert "打草稿" in reminder_lines(Settings(), facts(), random.Random(0), no_draft=True)[0]


def test_split_thinking_pulls_style_lines_out():
    from brain.inject import split_thinking
    s = Settings(sentinels={"thinking_style": True, "tool_reminder": True}, tool_reminder_every=1)
    before, think = split_thinking(lines(s, facts()), s)
    assert len(think) == 1 and think[0].startswith("〔想事的时候〕") and before == [TEXTS["zh"]["tool_reminder"]]
    own = Settings(thinking_style_text="〔想事〕先想三秒。", sentinels={"thinking_style": True, "tool_reminder": False})
    before, think = split_thinking(lines(own, facts()), own)
    assert think == ["〔想事〕先想三秒。", TEXTS["zh"]["think_lang"]] and before == []


def test_promise_phrases_recognized():
    from brain.inject import _PROMISE
    for said in ("那家记下了，以后你说想吃面我就往那儿翻。", "记住啦～", "我记着呢", "好，记下啦"):
        assert _PROMISE.search(said), said
    assert not _PROMISE.search("山西刀削面好吃是真的")


def test_promise_in_thinking_also_counts():
    """10-01：Lumi 心里想「顺手记一下：她说爱我这句，值一条记忆」，没调工具；下一轮也要提醒。"""
    import random
    from brain.inject import TurnFacts, reminder_lines
    from brain.settings import Settings
    s = Settings.from_dict({"lang": "zh"})
    f = TurnFacts(2, "早", "明天见。", [], last_thinking="顺手记一下：她说爱我这句，值一条记忆。")
    assert any(x.startswith("〔记住了〕") for x in reminder_lines(s, f, random.Random(0)))
    f2 = TurnFacts(2, "早", "明天见。", ["memory_remember"], last_thinking="顺手记一下")
    assert not any(x.startswith("〔记住了〕") for x in reminder_lines(s, f2, random.Random(0)))
