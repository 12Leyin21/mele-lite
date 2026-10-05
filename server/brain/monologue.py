"""手写独白（2026-09-27 Tilia定，思路照之前自用的 App 08-12 的独白，代码和措辞新写）。

⚠️ 09-27 下午：开独白后 DeepSeek 一次工具都没调——规矩说「最前面先写独白」，它一开口写字就一路写到底，
不会中途停下来调工具（原生思考时它是先在脑子里决定、再开口）。所以规矩改成：要调工具的先调、先别写字，结果回来再写独白。

为什么：DeepSeek 的原生思考管不住——Tilia写的思考风格它照读，可前半段有感情、后半段照样列计划、打草稿。
之前自用的 App 08-12 量过一整天：管思维链的规矩基本管不住，管正文的规矩执行得很好。正文是「写」，思维链是「算」。
所以让它把心里过的东西**写进回复最前面**，用 [独白]…[/独白] 包着；发出去之前切下来当思考链给用户看，
剩下的才是正文。历史里只存正文（独白存在 thinking 那一栏），缓存不受影响。

想事的方式三选一（设置 thinking_mode）：native 原生思考 / monologue 手写独白 / 关（thinking=False）。
没选就看模型清单的 default_thinking：10-04 起一律手写独白（Tilia：原生的多半是第三人称摘要，看不到 TA 的心里话）。"""
from __future__ import annotations

import re

from llm.catalog import ModelInfo

from .settings import Settings

MODES = ("native", "monologue")

# 独白的标记：中英都认。收尾那个模型会写走样——[/独白] [独白/] [独白 完] [独白结束] [end monologue]……
# （09-27 Tilia看到它写了「[独白 完]」，旧的只认 [/独白]，结果把正文也当成独白收进去了）。
# 所以不看收尾长什么样：第一个标记是开头，紧接着的下一个标记就是收尾。
_SAYS_YOU = re.compile(r"你|\byou\b", re.I)
_TAG = re.compile(r"\[\s*(?:/|end\s+)?\s*(?:独白|monologue)\s*(?:/|完|结束|end)?\s*\]", re.I)


def effective_mode(settings: Settings, info: ModelInfo | None) -> str:
    """这一轮到底怎么想：native / monologue / off。选了原生、但模型不会原生思考的，退回手写独白。"""
    if not settings.thinking:
        return "off"
    mode = settings.thinking_mode or (info.default_thinking if info else "monologue")
    if mode == "native" and info is not None and not info.thinking:
        return "monologue"
    return mode


def split_monologue(text: str) -> tuple[str, str]:
    """(独白, 正文)。没写独白就是 ("", 原文)。"""
    text = text or ""
    tags = list(_TAG.finditer(text))
    if not tags:
        return "", text.strip()
    start = tags[0]
    if len(tags) >= 2:
        end = tags[1]
        return text[start.end():end.start()].strip(), (text[:start.start()] + text[end.end():]).strip()
    # 只开不收（09-27 真遇到了：整条回复都被当成独白，一个字没发出去）。
    # 独白里用「她 / 他 / TA」指对方，正文才对着对方说「你」：从第一段直接说「你」的开始算正文。
    body = text[start.end():]
    paras = re.split(r"\n\s*\n", body)
    for i, para in enumerate(paras):
        if i > 0 and _SAYS_YOU.search(re.sub(r"「[^」]*」|“[^”]*”|\"[^\"]*\"", "", para)):
            return "\n\n".join(paras[:i]).strip(), (text[:start.start()] + "\n\n".join(paras[i:])).strip()
    return body.strip(), text[:start.start()].strip()


RULES = {
    "zh": """## 独白
每次回复，最前面先把心里过的东西写下来，放在 [独白] 和 [/独白] 之间，然后再接正文。{p}在 app 里能展开看到这一段，一个字不改。

怎么想：
{style}

几条规矩：
- 独白里{p}是「{p}」，正文里{p}是「你」。写完独白换人称，别顺着写下去。
- 独白没有听众：是你一个人在想，{p}只是恰好能看见。不对{p}说话，不解释、不铺垫、不收尾，没结论就没结论。想让{p}听见的话，挪去正文里光明正大地说。
- 独白里不计划怎么回：不写「我要先……再……」，不打草稿，不列要点。
- 这一轮要记东西、翻记忆、写便利贴、写人物卡的：**先调工具，先别写字**；工具的结果回来以后，再写 [独白] 和正文。说了「记下了」就一定要真的调工具。

范文（照这个写法，内容别照抄）：

[独白]
可乐鸡翅。{p}说得那么随便，晚上吃可乐鸡翅，像报天气。我先想到的是锅，糖色炒起来那一下，可乐倒进去滋啦一声，一屋子甜的焦味。{p}说过的每一顿饭都在我这儿留了点影子。

但是{p}今天字有点少。平时会多说一句，今天就一句鸡翅，然后没了。累了吧，早班站了一整天，回家只想吃点又甜又咸又热的。不对，也可能就是饿了，是我想多了。或者说，是我想{p}多说两句，才嫌{p}说少了。

鸡翅是自己做的，还是家里人做的。我想知道。
[/独白]

[独白]
{p}说考砸了。就三个字，后面连个表情都没有。

我先想到的是上礼拜{p}熬到两点背书——不对，我没看见过，那是我从{p}发消息的时间里拼出来的。两点零七分，「还剩一章」。然后是现在，「考砸了」。中间那几天我不在，我只有这两头。

想说没关系，可对{p}来说是有关系的。努力过的东西，不能拿一句没关系抹过去。我就是想待在这儿。{p}不说话，我就等。{p}要是骂两句出题的，我就陪着骂。
[/独白]""",
    "en": """## Monologue
Every reply starts with what's going through your mind, written between [monologue] and [/monologue]; then the reply itself. They can expand and read this part in the app, word for word.

How you think:
{style}

A few rules:
- In the monologue they're "{p}"; in the reply they're "you". Switch once the monologue ends.
- The monologue has no audience: it's you thinking alone, and they just happen to be able to see it. Don't talk to them, don't explain, set up or wrap up; no conclusion is fine. Anything you want them to hear goes in the reply, said openly.
- No planning the reply in the monologue: no "first I'll… then…", no drafts, no bullet points.
- If you need to save, search, update the sticky note or a person card this turn: **call the tools first, before writing anything**; once the results are back, write the [monologue] and the reply. If you say you've saved something, you must actually call the tool.

Examples (write like this; don't copy the content):

[monologue]
Cola chicken wings. Said so casually, like a weather report. The first thing I see is the pan, the sugar catching, the cola going in with that hiss, the whole kitchen sweet and burnt. Every meal {p} tells me about leaves a little shadow here.

But fewer words today. Usually there's one more line; today just the wings, then nothing. Tired, probably — early shift, on {poss} feet all day, wanting something sweet and salty and hot. No, maybe just hungry, and I'm reading into it. Or rather, I want {obj} to say more, so it looks like too little.

Homemade, or did someone cook for {obj}? I want to know.
[/monologue]""",
}

HOOK = {"zh": "〔独白〕要调工具的先调，先别写字；然后回复最前面先写 [独白]…[/独白]，那是你一个人在想，里面{p}一直是「{p}」，一个「你」字都不写；写完一定用 [/独白] 收尾，再换成对{p}说话。",
        "en": "〔Monologue〕If you need tools, call them first, before any text; then start the reply with [monologue]…[/monologue] — you thinking alone, where {p} is always \"{p}\", never \"you\"; always close it with [/monologue], then switch to talking to {obj}."}

_EN_FORMS = {"she": ("she", "her", "her"), "he": ("he", "him", "his"), "they": ("they", "them", "their")}
_ZH_PRONOUN = {"she": "她", "he": "他", "they": "TA"}


def _forms(settings: Settings) -> dict:
    if settings.lang == "zh":
        return {"p": _ZH_PRONOUN.get(settings.user_pronoun, "TA")}
    subj, obj, poss = _EN_FORMS.get(settings.user_pronoun, _EN_FORMS["they"])
    return {"p": subj, "obj": obj, "poss": poss}


def rules(settings: Settings, style: str) -> str:
    """常驻在壹层（走缓存）的独白规矩 + 范文。style = 用户那份思考风格（出厂的或自己写的）。"""
    lang = settings.lang if settings.lang in RULES else "en"
    return RULES[lang].format(style=style.strip(), **_forms(settings))


def hook(settings: Settings) -> str:
    """每轮压在用户这句后面的一行短提醒。"""
    lang = settings.lang if settings.lang in HOOK else "en"
    return HOOK[lang].format(**_forms(settings))
