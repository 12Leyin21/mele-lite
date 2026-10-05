from brain.monologue import effective_mode, hook, rules, split_monologue
from brain.settings import Settings
from llm.catalog import lookup


def test_split_monologue():
    assert split_monologue("[独白]\n她说考砸了。\n[/独白]\n\n没事，我在。") == ("她说考砸了。", "没事，我在。")
    assert split_monologue("[独白]想她[独白/]好呀") == ("想她", "好呀")                  # 闭合写反了也认
    assert split_monologue("[独白]\n想她\n[独白 完]\n\n好呀") == ("想她", "好呀")        # 09-27 真遇到的写法
    assert split_monologue("[独白]想她[独白结束]好呀") == ("想她", "好呀")
    assert split_monologue("[monologue]x[end monologue]Hi") == ("x", "Hi")
    assert split_monologue("[monologue]thinking[/monologue]\nHi") == ("thinking", "Hi")
    assert split_monologue("[独白]忘了收尾，全是独白") == ("忘了收尾，全是独白", "")
    unclosed = "[独白]\n她说要去凯恩斯潜水。\n\n然后呢——我想她说「你呢」的样子。\n\n凯恩斯！你是想看大堡礁吗？\n\n带上防晒。"
    assert split_monologue(unclosed) == ("她说要去凯恩斯潜水。\n\n然后呢——我想她说「你呢」的样子。",
                                         "凯恩斯！你是想看大堡礁吗？\n\n带上防晒。")          # 没收尾：从第一段对着说「你」的算正文
    assert split_monologue("就一句正文") == ("", "就一句正文")


def test_effective_mode_follows_setting_then_model():
    flash, sonnet, haiku = lookup("deepseek-flash"), lookup("claude-sonnet-5"), lookup("claude-haiku-4-5")
    assert effective_mode(Settings(), flash) == "monologue" and effective_mode(Settings(), sonnet) == "monologue"   # 10-04：一律默认独白
    assert effective_mode(Settings(thinking_mode="native"), sonnet) == "native"
    assert effective_mode(Settings(thinking_mode="native"), flash) == "native"
    assert effective_mode(Settings(thinking_mode="native"), haiku) == "monologue"          # 不会原生思考的退回独白
    assert effective_mode(Settings(thinking=False), sonnet) == "off"
    assert effective_mode(Settings(), None) == "monologue"                                 # 清单外的模型也默认独白


def test_rules_and_hook_follow_pronoun():
    r = rules(Settings(user_pronoun="she"), "我让念头自己流。")
    assert "[独白] 和 [/独白]" in r and "我让念头自己流。" in r and "独白里她是「她」，正文里她是「你」" in r
    assert "{" not in r and "可乐鸡翅" in r
    assert hook(Settings()).startswith("〔独白〕要调工具的先调，先别写字；") and hook(Settings()).endswith("再换成对TA说话。")
    assert "先调工具，先别写字" in rules(Settings(), "x")
    # 09-28 Tilia：独白写着写着对 TA 说起「你」来——每轮的短提醒里点名不许
    assert "里面她一直是「她」，一个「你」字都不写" in hook(Settings(user_pronoun="she"))
    en_hook = hook(Settings(lang="en", user_pronoun="he"))
    assert 'he is always "he", never "you"' in en_hook and "{" not in en_hook
    en = rules(Settings(lang="en", user_pronoun="he"), "I let thoughts flow.")
    assert "In the monologue they're \"he\"" in en and "{" not in en
