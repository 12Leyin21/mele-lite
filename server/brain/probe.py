"""召回哨兵（2026-09-28，召回改造第 3 步；思路见 docs/research/2026-09-recall-ideas.md 第 1 条）。

以前拿 TA 的原句（带上它上一句）直接去搜：「它回来就一直蔫蔫的」「上周那次」原样算向量，「它」「上周」都没解开。
现在先让便宜的小模型读「今天几号星期几 + 最近三句 + 这一句」，产出：
- recall：要不要翻；
- topic：保留 TA 原话和口吻、只把代词换掉的一句（跟原句各算一个向量，取更像的；之前自用的 App 09-28 教训：只用话题会丢原句的词，
  改成旁白会跟记忆的写法对不上）；
- keywords：稀有关键词（拿去关键词榜；称呼、常见词记忆服务那边还会再滤一遍）；
- date_from / date_to：说到了具体哪几天就给（只用来收窄候选，记忆服务那边前后各放宽一天，没有就回落到全集）。
兜底：哨兵出错、超时、吐的不是 JSON → 返回 None，照原句召回（不比以前差）；
「上次 / 还记得 / 说过」一类问法命中 → 强制翻，哪怕它说不用。"""
from __future__ import annotations

import asyncio
import json
import logging
import re
from datetime import date

from llm.router import call
from llm.types import Block, ChatRequest, Msg
from memory.models import Probe

log = logging.getLogger(__name__)
TIMEOUT = 8.0          # 秒：超时就当哨兵没来，照原句
FORCE = re.compile(r"上次|还记得|记不记得|记得吗|之前(?:跟你)?说|说过|以前(?:跟你)?说|那次|remember|last time|told you|mentioned",
                   re.IGNORECASE)
WEEKDAYS = {"zh": "一二三四五六日", "en": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]}

PROMPT = {
    "zh": """你是记忆检索前的「听懂这句话」的一步。读下面的对话，判断 TA 这句要不要去翻以前的记忆，并把要搜的东西整理出来。

今天：{today}（星期{weekday}）
最近几句：
{recent}
TA 这句：{text}

只输出一个 JSON，不要别的字：
{{"recall": true/false, "topic": "…", "keywords": ["…"], "date_from": "YYYY-MM-DD 或 null", "date_to": "YYYY-MM-DD 或 null"}}

- recall：只要沾到 TA 自己——身体、吃喝、家人朋友、宠物、工作学习、计划、心情、以前说过的事——就 true，
  哪怕是在问问题（「吃芒果可以吗」「给我妈送什么」都要翻）；拿不准也 true。
  只有纯寒暄、应答、跟 TA 自己无关的常识题和算题，才 false。
- topic：保留 TA 的原话和口吻，只把代词（它、他、她、那边、那次）换成最近几句里指的东西；不要改写成「TA 问……」这种旁白。
- keywords：一到三个最能定位那件事的词（人名、宠物名、地名、物件、事件），别放称呼和常见词。
- date_from / date_to：TA 说到了具体的时间（上周、昨天、上个月、三号），换成日期；没说就都是 null。""",
    "en": """You are the "understand this line" step before a memory search. Read the chat below, decide whether the latest line
should look up older memories, and prepare what to search for.

Today: {today} ({weekday})
Recent lines:
{recent}
Their line: {text}

Output one JSON object and nothing else:
{{"recall": true/false, "topic": "…", "keywords": ["…"], "date_from": "YYYY-MM-DD or null", "date_to": "YYYY-MM-DD or null"}}

- recall: true whenever it touches them — body, food, family and friends, pets, work or study, plans, mood, anything said
  before — even as a question ("can I eat mango?", "what should I get my mum?"); if unsure, true. false only for pure
  greetings, acknowledgements, and general-knowledge or maths questions that aren't about them.
- topic: keep their own words and tone; only replace pronouns (it, he, she, there, that time) with what the recent lines
  refer to. Don't rewrite it as narration ("they asked about…").
- keywords: one to three words that pin the thing down (names, pets, places, objects, events); no nicknames or common words.
- date_from / date_to: if they mention a specific time (last week, yesterday, the 3rd), convert to dates; otherwise null.""",
}


def forced(text: str) -> bool:
    return bool(FORCE.search(text or ""))


def _date(v) -> date | None:
    try:
        return date.fromisoformat(str(v)) if v not in (None, "", "null") else None
    except ValueError:
        return None


def parse(raw: str, text: str) -> Probe | None:
    """模型吐的东西 → Probe；看不懂就 None（调用方照原句）。"""
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    kws = [str(k).strip() for k in d.get("keywords") or [] if str(k).strip()][:3]
    lo, hi = _date(d.get("date_from")), _date(d.get("date_to"))
    if lo and hi and lo > hi:
        lo, hi = hi, lo
    return Probe(recall=bool(d.get("recall")) or forced(text), topic=str(d.get("topic") or "").strip()[:100],
                 keywords=tuple(kws), date_from=lo or hi, date_to=hi or lo)


async def probe(adapter, model: str, text: str, recent: list[str], *, lang: str = "zh",
                today: date | None = None) -> Probe | None:
    """跑一次哨兵。出错、超时、看不懂都返回 None。返回的 Probe.usage 是这次花的 token（调用方记账）。"""
    today = today or date.today()
    wd = WEEKDAYS[lang][today.weekday()]
    prompt = PROMPT[lang].format(today=today.isoformat(), weekday=wd, text=text,
                                 recent="\n".join(recent[-3:]) or ("（刚开始聊）" if lang == "zh" else "(start of chat)"))
    req = ChatRequest(model=model, system=[Block("只输出 JSON。" if lang == "zh" else "Output JSON only.")],
                      messages=[Msg("user", prompt)], max_tokens=300, thinking=False)
    try:
        reply = await asyncio.wait_for(call(adapter, req), TIMEOUT)
    except Exception as e:                      # 哨兵挂了不能拖垮这一轮
        log.warning("recall probe failed, falling back to the raw line: %s", e)
        return None
    out = parse(reply.text, text)
    if out is None:
        log.warning("recall probe gave something unreadable, falling back: %r", (reply.text or "")[:200])
        return None
    out.usage = reply.usage
    return out

