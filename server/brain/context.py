"""拼请求：按命中缓存的顺序从前往后码好（设计文档第三段）。

  工具定义（按名字排好）→ 壹：产品底子 + 人设 + 核心 📌① → 贰：账本 + 腔调样本 📌②
  → 叁：最近原文（最后一条挂滚动书签 📌③）→ 最后一条用户消息 = 会变区 + 用户这句话

会变区只在这一轮临时拼进最后一条，**不存进历史**：下一轮的历史里这句话只剩原话，
所以上一轮的前缀逐字节原样出现在下一轮开头，缓存接得上。"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, replace
from datetime import datetime
from zoneinfo import ZoneInfo

import memory as M
from llm.types import Block, ChatRequest, Msg, ToolSpec

HEADER = {"zh": "〔以下是 app 附上的参考，不是对方说的话〕",
          "en": "〔Notes attached by the app — not the user's words〕"}
LEAD_IN = {"zh": "（更早的对话在账本里）", "en": "(Earlier conversation is in the ledger.)"}
_WEEK = {"zh": "一二三四五六日", "en": ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")}
_L = {"zh": {"now": "〔现在〕", "recall": "〔记忆浮上来〕", "about": "〔关于 TA〕", "sticky": "〔便利贴〕"},
      "en": {"now": "〔Now〕", "recall": "〔Memories that came up〕", "about": "〔About them〕", "sticky": "〔Sticky note〕"}}


@dataclass
class ContextParts:
    tools: list[ToolSpec]
    base: str            # 壹
    ledger: str          # 贰（空 = 还没有账本）
    history: list[Msg]   # 叁，旧的在前
    volatile: str        # 会变区
    user_text: str
    tail: str = ""       # 压在用户这句后面、离它开口最近的：思考风格（照之前自用的 App「压在消息最末尾」，09-27）
    images: tuple = ()   # 这一轮 TA 发的图（只给会看图的模型；历史里用描述）


def user_tag(user_id) -> str:
    """给中转站粘后端用的固定标记：同一个人永远一样，但看不出是谁。"""
    return hashlib.sha256(f"newapp:{user_id}".encode()).hexdigest()[:32]


def build_request(parts: ContextParts, *, model: str, thinking: bool, user_tag: str, lang: str = "zh",
                  max_tokens: int = 8000) -> ChatRequest:
    system = [Block(parts.base, cache=True)]
    if parts.ledger.strip():
        system.append(Block(parts.ledger, cache=True))
    history = list(parts.history)
    if history and history[0].role == "assistant":
        history.insert(0, Msg("user", LEAD_IN[lang]))     # 对话必须从用户开口
    if history:
        history[-1] = replace(history[-1], cache=True)    # 滚动书签
    final = f"{parts.volatile}\n\n{parts.user_text}" if parts.volatile.strip() else parts.user_text
    if parts.tail.strip():
        final = f"{final}\n\n{parts.tail}"
    return ChatRequest(model=model, system=system, messages=history + [Msg("user", final, images=tuple(parts.images))],
                       tools=list(parts.tools), max_tokens=max_tokens, thinking=thinking, user_tag=user_tag)


def render_volatile(*, now: datetime, tz: str, lang: str, recall, sticky: str, lines: list[str]) -> str:
    L = _L[lang]
    local = now.astimezone(ZoneInfo(tz))
    wd = _WEEK[lang][local.weekday()]
    when = (f"{local:%Y-%m-%d %H:%M} 周{wd}（{tz}）" if lang == "zh"
            else f"{local:%Y-%m-%d %H:%M} {wd} ({tz})")
    out = [HEADER[lang], f"{L['now']}{when}"]
    if recall is not None:
        for section, want_about in (("recall", False), ("about", True)):
            got = ([f"- {m.content}" for m in recall.full if (m.kind == "about") == want_about]
                   + [f"- {l.snippet}" for l in recall.lines if (l.kind == "about") == want_about])
            if got:
                out.append(L[section])
                out.extend(got)
        for p in recall.people:
            out.append(M.render_person(p, lang))
            for m in recall.linked.get(p.id, []):     # 跟这个人有关的几条记忆，顺着卡一起递（09-27）
                day = m.created_at.astimezone(ZoneInfo(tz)).date().isoformat()
                out.append(f"- 跟{p.name}有关（{day}）：{m.content}" if lang == "zh"
                           else f"- About {p.name} ({day}): {m.content}")
    if sticky.strip():
        out.append(f"{L['sticky']}{sticky.strip()}")
    out.extend(lines)
    return "\n".join(out)
