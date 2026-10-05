"""Lumi 的说明书（照之前自用的 App的格式，Tilia 2026-09-26 定）：
- manuals/<语言>/lumi.md：速查 + 手册目录，每轮都在（放在壹层，走缓存）。
- manuals/<语言>/<功能>.md：每个功能一本。第一行标 <!-- mode: always --> 或 <!-- mode: on-demand -->：
  · always（常驻）：全文附在 lumi.md 后面，也在壹层走缓存——天天用的功能，不用翻、不会慢；
  · on-demand（现翻）：目录里只有一行，用到时 Lumi 调 read_manual 翻——偶尔才用、细则又长的功能。
  翻一次吃不到缓存、还要多调一次模型，所以只给少用的功能。常驻的要写短：真正要省的是注意力。"""
from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).with_name("manuals")
_MODE = re.compile(r"^<!--\s*mode:\s*(always|on-demand)\s*-->\s*\n?")


@dataclass(frozen=True)
class Manual:
    name: str
    mode: str          # always / on-demand
    text: str


@lru_cache
def load(lang: str) -> tuple[str, tuple[Manual, ...]]:
    folder = ROOT / lang
    index = (folder / "lumi.md").read_text(encoding="utf-8").strip()
    out = []
    for p in sorted(folder.glob("*.md")):
        if p.stem == "lumi":
            continue
        raw = p.read_text(encoding="utf-8")
        m = _MODE.match(raw)
        if not m:
            raise ValueError(f"{p}: 第一行要写 <!-- mode: always --> 或 <!-- mode: on-demand -->")
        out.append(Manual(p.stem, m.group(1), raw[m.end():].strip()))
    return index, tuple(out)


_TALK = {"zh": "## 说话", "en": "## How you talk"}
# 线下生活（10-05 Tilia）关着时：说明书里「你有自己的一天」那两行换掉（跟 MeleLiteCore Prompts/*/modes.md 的 life_off 同一句）
_LIFE_OFF = {
    "zh": (("### 你有自己的一天\n- 在忙什么、刚看见什么、正为什么事烦，都可以顺口提，话题不用总围着 TA 转。\n"
            "- 你也会吃饭、出门、犯困——这些就是你的生活，照实说。\n"),
           "### 你的日子\n- 你的日子就是和 TA 说话的这些时候：在想什么、刚注意到什么、正惦记什么，都可以顺口提，话题不用总围着 TA 转。\n"),
    "en": (("### You have your own day\n- What you're busy with, something you just saw, something bugging you — mention it in passing; "
            "the conversation doesn't have to orbit them.\n- You eat, go out, get sleepy too; that's your life, say it as it is.\n"),
           "### Your days\n- Your days are the times you spend talking with them: what you're thinking about, something you just noticed, "
           "something on your mind — mention it in passing; the conversation doesn't have to orbit them.\n"),
}


# 说话规矩（10-05 Tilia：用户能换掉出厂的说话风格）：说明书「格式」里这两条，用户写了就换成他的（分段发消息、纯文字是机制，不换）
_TALK_FACTORY = {
    "zh": ("- 大多数时候回一两句就够，像随手回微信：接住 TA 这一句，加一点你自己的反应，或者问一件小事，就停。TA 说得长、聊到要紧的事，你再多说几句。\n"
           "- 线上就是发消息：想说的直接说出来，一句是一句。\n"),
    "en": ("- Most of the time a line or two is enough, like a quick text back: pick up what they just said, add a bit of your own reaction "
           "or ask one small thing, and stop. When they write a lot or it's something that matters, say more.\n"
           "- Online, you're just texting: say what you want to say straight out, every line is a line you actually send.\n"),
}


def render_handbook(lang: str, chat_rules: bool = True, life: bool = True, talk: str = "") -> str:
    """chat_rules=False（长文模式，10-01 Tilia）：说明书里「说话」那一节（短消息、像真人发微信）整节拿掉，
    人设 / 角色卡自己的文风说了算；日常模式照旧保留。"""
    index, ms = load(lang)
    if not chat_rules:
        head = _TALK.get(lang, _TALK["en"])
        start = index.find(head)
        if start >= 0:
            end = index.find("\n## ", start + len(head))
            index = (index[:start] + (index[end + 1:] if end >= 0 else "")).rstrip() + "\n"
    if not life:
        old, new = _LIFE_OFF.get(lang, _LIFE_OFF["en"])
        index = index.replace(old, new)
    if talk.strip():
        mine = "".join(f"- {x.strip().lstrip('-').strip()}\n" for x in talk.strip().splitlines() if x.strip())
        index = index.replace(_TALK_FACTORY.get(lang, _TALK_FACTORY["en"]), mine)
    return "\n\n".join([index, *(m.text for m in ms if m.mode == "always")])


def manual_names(lang: str) -> list[str]:
    return [m.name for m in load(lang)[1]]


def read_manual(name: str, lang: str) -> str | None:
    wanted = (name or "").strip().lower().removesuffix(".md")
    return next((m.text for m in load(lang)[1] if m.name == wanted), None)
