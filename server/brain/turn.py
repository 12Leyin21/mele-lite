"""一轮对话：大脑的主流程（设计文档第一段「一轮对话」）。

  存下这句 → 想起相关的记忆和人物卡 → 按缓存顺序拼上下文 → 调模型（带工具循环，最多 8 次）
  → 写完再均匀切成气泡，一条一条推 → 存档、记账 → 上下文满了就卷账本

所有外部的东西（数据库、向量、钥匙、模型接头、时间、等待、骰子）都从 Deps 进来，测试时全换成假的。
记忆服务出错不让这一轮失败：这一轮不带记忆照常回话（设计文档「出错时」）。"""
from __future__ import annotations

import asyncio
import time
import base64
import hashlib
import inspect
import logging
import random
from dataclasses import asdict, dataclass, field, replace
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable
from uuid import UUID
from zoneinfo import ZoneInfo

import memory as M
from llm.catalog import DEFAULT_HIGH_WATER, cost, lookup, sees_images
from llm.errors import LLMError
from llm.router import Route, call, make_adapter
from llm.types import ChatRequest, ImagePart, Msg, ToolRound, Usage

from . import archive, attachments as files, books, context_line, diary, drawer, far_dates, focus, hidden, ledger, lore, mcp, probe as sentinel, reactions, tarot, vision, voice, wallet
from .judge import LLMJudge
from .bubbles import split_reply, typing_delay
from .context import ContextParts, build_request, render_volatile, user_tag
from . import monologue
from .inject import TEXTS, TurnFacts, reminder_lines, split_thinking, thinking_style
from .scope import Scope
from .persona import Persona, render_base, tone_lines
from .settings import Settings
from . import edits, keepalive
from food import store as food_store
from music import ears

from .auth import TrialOver, charge_trial
from .edits import EditRef
from .tools import INCOGNITO_TOOLS, ToolContext, run_tool, tool_note, tool_specs
from .wake_text import monologue_note, split_silent

log = logging.getLogger(__name__)

TOOL_ROUNDS_MAX = 8
LEDGER_FAIL_WARN = 3
Emit = Callable[[dict], Awaitable[None]]

USER_ERRORS = {
    "zh": {"auth": "模型的 key 好像不对，去设置里检查一下。",
           "balance": "模型那边的余额不够了，充值以后再来找我。",
           "model": "设置里的模型名找不到，检查一下拼写。",
           "rate": "模型那边太忙了，等一会儿再试。",
           "overloaded": "模型那边太忙了，等一会儿再试。",
           "network": "连不上模型，检查一下网络。",
           "bad_request": "这次请求被模型拒了，稍后再试试。",
           "other": "模型那边出了点问题，稍后再试。",
           "trial_over": "今天的免费额度用完啦，明早 5 点会补一些。加一个自己的 key，或者成为会员，就不用等——之前聊的、我记下的都还在。"},
    "en": {"auth": "The model key doesn't seem right — check it in Settings.",
           "balance": "The model account is out of credit. Top it up and come back.",
           "model": "The model name in Settings wasn't found — check the spelling.",
           "rate": "The model is busy right now. Try again in a moment.",
           "overloaded": "The model is busy right now. Try again in a moment.",
           "network": "Can't reach the model — check the connection.",
           "bad_request": "The model rejected this request. Try again later.",
           "other": "Something went wrong on the model's side. Try again later.",
           "trial_over": "Today's free allowance is used up — a little more comes back at 5 am. Add your own key or become a member to skip the wait — everything we said and everything I remembered is still here."},
}
LAST_ROUND_NOTE = {"zh": "\n（这一轮能调工具的次数用完了，接下来直接回话。）",
                   "en": "\n(That was the last tool call allowed this turn — reply directly now.)"}
LEDGER_NOTICE = {"zh": "账本最近几次都没写成功，旧的对话先原样留着，只是每轮会贵一点。可以在设置里换一个写账本的模型。",
                 "en": "The ledger hasn't been written the last few times. Older messages stay as they are for now, "
                       "which makes each turn a bit more expensive. You can pick another ledger model in Settings."}


@dataclass
class Deps:
    pool: object
    embedder: object
    keys: object                                    # 有 route_for(user_id) -> Route
    adapter_for: Callable[[Route], object] = make_adapter
    reranker: object = None
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    sentinel: bool = False       # 召回哨兵的总闸：正式接口和测试台开（api/web 的 __main__）；测试默认关，免得吃掉假模型的剧本
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep
    rng: random.Random = field(default_factory=random.Random)
    caption_route: Route | None = None              # 我们的看图模型：用户的模型看不见图、钥匙串里也没有会看图的 key 时用
    probe_keys: bool = False     # 加钥匙前先拿它试打一次（正式接口开；测试默认关，免得吃掉假模型的剧本）
    adapters: dict = field(default_factory=dict)
    off_get: object = None       # 查营养（Open Food Facts）的传输；空 = 真联网，测试里换假的（09-29）
    music: object = None         # music.apple.AppleMusic；没配 MusicKit 钥匙 = None（09-30）
    ears: object = None          # music.ears.Transport：Lumi 的耳朵（下载 / 解码 / 量 / 歌词 / Gemini）；None = 不去听（测试默认）
    tts_for: Callable[[str], object] | None = None   # 声音（10-03）：给一把 ElevenLabs key 返回接头；None = 没有声音
    tts_key: str = ""            # 我们的 ElevenLabs key（NEWAPP_ELEVENLABS_KEY）；空 = 只有自带 key 的人能用
    files_dir: Path | None = None   # 语音存哪（接口启动时填 ApiConfig.files_dir）


def get_adapter(deps: Deps, route: Route):
    key = (route.provider, route.base_url, route.api_key)
    if key not in deps.adapters:
        deps.adapters[key] = deps.adapter_for(route)
    return deps.adapters[key]


@dataclass
class TurnOutcome:
    said: bool                   # 它这一轮说了话（醒来时回 <silent> 就是 False）
    cost_usd: float = 0.0
    error: str | None = None     # 模型报错的种类 / trial_over


@dataclass
class LoopResult:
    text: str
    thinking: str
    usage: Usage
    tools_used: list[str]
    last_prompt: int
    tool_notes: list[str] = field(default_factory=list)   # 用过的工具，一行一个，存进存档给下一轮看
    cards: list[dict] = field(default_factory=list)       # 挂出来给 TA 看的动作卡片，跟回复一起存


async def tool_loop(adapter, req: ChatRequest, ctx: ToolContext, emit: Emit, lang: str,
                    max_rounds: int = TOOL_ROUNDS_MAX) -> LoopResult:
    """调模型；它要调工具就执行、把结果还给它、接着调。看的是回复里有没有工具请求，不看它自报的停下原因。
    最多 max_rounds 个来回：最后一个来回的结果里告诉它「次数用完了」，再调一次就收尾。"""
    total = Usage()
    thinking: list[str] = []
    used: list[str] = []
    notes: list[str] = []
    retried = False                          # 只写了独白没写正文的，再叫一次（只一次）
    shown: set[tuple[str, str]] = set()      # 一轮里同样的卡只挂一张（翻了好几回记忆 → 一张「翻了些记忆」）
    cards: list[dict] = []
    for round_no in range(max_rounds + 1):
        reply = await call(adapter, req)
        total = total + reply.usage
        if reply.thinking.strip():
            thinking.append(reply.thinking.strip())
        mono, said = monologue.split_monologue(reply.text)    # 手写独白：切下来当思考链；调工具前那一段也要切
        if mono:
            thinking.append(mono)
        if not reply.tool_calls and mono and not said and not retried and round_no < max_rounds:
            # 09-27 深夜：它写了一小段独白就停了，正文空的。补一句提醒再叫一次；第一次那段独白不留（第二次会重写）
            retried = True
            thinking.pop()
            last = req.messages[-1]
            req.messages[-1] = replace(last, text=f"{last.text}\n\n{MONO_ONLY_NOTE[lang]}")
            continue
        if not reply.tool_calls or round_no == max_rounds:
            return LoopResult(said, "\n\n".join(thinking), total, used, reply.usage.prompt_total, notes, cards)
        results = []
        for c in reply.tool_calls:
            before = len(ctx.cards)
            results.append(await run_tool(ctx, c))
            used.append(c.name)
            notes.append(tool_note(c.name, c.args, results[-1], lang))
            for card in ctx.cards[before:]:
                if (card.kind, card.text) in shown:
                    continue
                shown.add((card.kind, card.text))
                if not card.private:
                    cards.append({"kind": card.kind, "text": card.text, **({"data": card.data} if card.data else {})})
                await emit({"type": "card", "kind": card.kind, "text": card.text, "private": card.private,
                            **({"data": card.data} if card.data else {})})
                if card.kind == "relationship":       # 卡不挂，但手机要知道：名字旁边的图标换一下（09-29）
                    await emit({"type": "relationship", "to": (card.data or {}).get("to", "")})
        if round_no == max_rounds - 1:
            results = [r + LAST_ROUND_NOTE[lang] for r in results]
        req.rounds.append(ToolRound(reply.raw_assistant, list(reply.tool_calls), results))
    raise AssertionError("unreachable")


MONO_ONLY_NOTE = {"zh": "（你刚才只写了独白就停了，没写正文。独白照常写，写完一定接着写正文。）",
                  "en": "(Last time you wrote only the monologue and stopped. Write the monologue as usual, then always go on to the reply.)"}

TOOLS_HEAD = {"zh": "〔上一轮你用过：{}〕", "en": "〔Last turn you used: {}〕"}


def history_msgs(stored: list[archive.StoredMsg], lang: str) -> tuple[list[Msg], str]:
    """存档 → 历史。它说的话后面要是用过工具，就在紧接着的那句用户的话前面加一行〔上一轮你用过：…〕
    （09-27：它看不见以前的工具调用，每轮都以为还没记、又记一遍）。放在用户那一侧，它不容易学着在回话里写；
    每次都从存档原样生成，历史逐字节不变，缓存接得上。返回 (历史, 还没着落的那行)——最后一轮的那行给这一轮的用户话。"""
    sep = "、" if lang == "zh" else "; "
    out: list[Msg] = []
    pending = ""
    for m in stored:
        if m.role in archive.USER_SIDE:
            out.append(Msg("user", with_tools_note(pending, m.text)))
            pending = ""
        else:
            out.append(Msg("assistant", m.text))
            pending = TOOLS_HEAD[lang].format(sep.join(m.tools.splitlines())) if m.tools.strip() else ""
    return out, pending


def with_tools_note(note: str, text: str) -> str:
    return f"{note}\n{text}" if note else text


async def resolve_route(keys, scope: Scope) -> Route:
    """这一轮走哪把钥匙：正式的钥匙串按联系人找（DbKeys.route_for_scope，可能是试用钥匙）；本机测试的 FileKeys 按账号。"""
    f = getattr(keys, "route_for_scope", None)
    r = f(scope) if f else keys.route_for(scope.account)
    return await r if inspect.isawaitable(r) else r


_PRONOUN = __import__("re").compile(r"[它他她那这]|\b(it|he|she|they|that|there)\b", __import__("re").I)


def _recent_lines(settings: Settings, persona, history) -> list[str]:
    """最近三句，给哨兵和判读器看：「名字：原话」。"""
    who = settings.user_name or ("TA" if settings.lang == "zh" else "Them")
    return [f"{who if m.role in archive.USER_SIDE else persona.name}：{m.text}" for m in history[-3:] if m.text.strip()]


async def _probe(deps: Deps, scope: Scope, route: Route, settings: Settings, persona, history, text: str, day,
                 now: datetime):
    """召回哨兵（09-28）：先听懂这句再去搜。纯寒暄不跑（省钱）；带代词、「上次」的短句照跑。
    用这把钥匙的便宜模型（账本那个），花的钱记到账号上。出错返回 None，召回照原句。"""
    t = (text or "").strip()
    if not t or not (M.worth_recalling(t) or sentinel.forced(t) or _PRONOUN.search(t)):
        return None
    recent = _recent_lines(settings, persona, history)
    model = route.ledger_model or route.chat_model
    got = await _safe(sentinel.probe(get_adapter(deps, route), model, t, recent, lang=settings.lang, today=day), None)
    if got is not None and got.usage is not None:
        await _safe(archive.add_usage(deps.pool, scope.account, day, model, got.usage, cost(got.usage, model)), None)
    return got


async def _safe(coro, default):
    try:
        return await coro
    except Exception:
        log.exception("memory service call failed; this turn goes without it")
        return default


async def _account(pool, user_id: UUID, day: date, model: str, usage: Usage) -> None:
    await archive.add_usage(pool, user_id, day, model, usage, cost(usage, model))


def now_and_then(state: dict, name: str, content: str, now: datetime, *, wake: bool) -> str:
    """会变的东西别每轮都给（09-30 Tilia）：变了才给、隔两小时再给、醒来时给——跟〔TA 那边〕一个规矩。
    state 里记上次给的时间和内容指纹；空的不给也不记。"""
    if not content.strip():
        return ""
    key = hashlib.sha1(content.encode()).hexdigest()[:12]
    last_at, last_key = state.get(f"{name}_at"), state.get(f"{name}_key")
    if not (wake or not last_at or last_key != key or now - datetime.fromisoformat(last_at) >= context_line.RESHOW):
        return ""
    state[f"{name}_at"], state[f"{name}_key"] = now.isoformat(), key
    return content


async def run_turn(deps: Deps, scope: Scope | UUID, text: str, emit: Emit, *, resend: bool = False,
                   wake: str | None = None, attachments: list | None = None,
                   pieces: list[str] | None = None, free_trial: bool = False, quiet_food: bool = False) -> TurnOutcome:
    """scope = 这一轮在谁的名下（brain/scope.py）：设置、人设、记忆归联系人，聊天、账本、状态归窗口，用量归账号。
    resend = 重新生成：用户那句已经在存档最后了（刚撤掉了它的回复），不再存一遍，直接再回一次。
    wake = 它自己醒来（巡逻）：这段〔醒来〕代替用户的话。它想事时的动静先压着，回 <silent> 就全丢、什么都不存；
    开口了才把压着的放出去，〔醒来〕存成 wake 角色、回复照常存。醒来时出错不推给用户，交给巡逻记账。
    pieces = 等候区拼成 text 之前的那几句，跟着存下来，app 按它还原成几个气泡。
    free_trial = 这一轮不扣免费额度（初见那一轮，09-28）。
    quiet_food = 这一轮不给〔饮食〕那行（记一餐说一句，09-30：不让它看见热量；那几条留到下一轮再告诉它）。"""
    scope = Scope.of(scope)
    acc, comp, conv = scope.account, scope.companion, scope.conversation
    real_emit, held = emit, []
    if wake:
        async def emit(ev: dict) -> None:        # noqa: F811 —— 醒来时先压着
            held.append(ev)
    pool = deps.pool
    now = deps.now()
    settings = Settings.from_dict(await archive.get_settings(pool, comp))
    if scope.incognito:          # 无痕：它不知道对面是 TA——连名字、怎么指代都不给（Tilia 09-27 定）
        settings = replace(settings, user_name="", user_pronoun="they")
    lang = settings.lang
    day = now.astimezone(ZoneInfo(settings.tz)).date()
    persona = Persona.from_dict(await archive.get_persona(pool, comp), lang)
    if scope.incognito:
        persona = replace(persona, call_user="")
    state = await archive.get_state(pool, conv)
    turn_no = int(state.get("turn_count", 0)) + 1
    history = await files.decorate(pool, await archive.unrolled(pool, conv), lang)   # 带附件的那几句接上〔图片〕〔文件〕
    text_for_model, sent = text, []
    if wake:
        said = None
        text = next((m.text for m in reversed(history) if m.role == "user"), "")   # 联想拿 TA 最后说的那句当线索
    elif resend:
        if not history or history[-1].role != "user":
            raise ValueError("没有可以重新回的那句")
        said, history = history[-1], history[:-1]
        text = text_for_model = said.text
    else:
        said = await archive.add_message(pool, conv, "user", text, parts=pieces, now=now)
        sent = await files.claim(pool, conv, attachments, said.id) if attachments else []
        text_for_model = "\n".join([text, *(files.note(f, lang) for f in sent)]).strip()
    edit_ref = None if scope.incognito or said is None else EditRef(conv, said.id)   # 倒回时按这一轮撤回它写过的东西
    try:
        route = await resolve_route(deps.keys, scope)
    except TrialOver:
        await emit({"type": "error", "kind": "trial_over", "message": USER_ERRORS[lang]["trial_over"]})
        await emit({"type": "done"})
        return TurnOutcome(False, error="trial_over")
    adapter = get_adapter(deps, route)
    # 免费额度按这一轮真花的钱扣（连同哨兵、判读、看图、卷账本）：开始前记下今天的总花费，结束时算差
    trial_mark = (await archive.usage_on(pool, acc, day))["cost_usd"] if route.trial and not free_trial else None
    images: tuple = ()
    if sent:                          # TA 这一轮发了图：先写好描述，会看图的模型这一轮另外看原图
        for f in sent:
            if f.kind == "image":
                await _safe(vision.describe(deps, scope, route, f, lang, day, lambda r: get_adapter(deps, r)), "")
        text_for_model = "\n".join([text, *(files.note(f, lang) for f in sent)]).strip()
        if sees_images(route.provider):
            images = tuple(ImagePart(f.mime, base64.b64encode(Path(f.path).read_bytes()).decode())
                           for f in sent if f.kind == "image" and not f.sticker_id)   # 表情包只给描述（10-01）
    last_assistant = next((m.text for m in reversed(history) if m.role == "assistant"), "")

    names = (persona.name, persona.call_user, settings.user_name)   # 称呼不进关键词榜：它的名字、它怎么叫 TA、TA 的名字（09-28 召回改造第 1 步）
    heard = await _probe(deps, scope, route, settings, persona, history, text, day, now) \
        if deps.sentinel and settings.recall_probe and settings.recall_level != "off" and not scope.incognito else None
    # 细读：正式接口用大模型判读器判灰区（09-28 评测 medium 对13/错0/漏3，本地精排反而净亏）；没有真模型的测试里用本地精排
    judge = None
    if settings.careful_read and not scope.incognito:
        judge = LLMJudge(get_adapter(deps, route), route.ledger_model or route.chat_model,
                         _recent_lines(settings, persona, history), settings.lang) if deps.sentinel else deps.reranker
    # 一潮之内同一条记忆只想起一次（09-27 Tilia定：按潮不按钟点，有的潮不到六小时）；卷账本时清空
    seen = {int(k) for k in (state.get("recall_seen") or [])}
    hidden_people = await _safe(hidden.hidden_for(pool, comp), frozenset())   # 对它隐藏的人物卡（10-01）
    recall = None if scope.incognito or not text.strip() else await _safe(M.recall(
        pool, deps.embedder, comp, text, people_owner=acc, context=last_assistant or None,
        level=settings.recall_level, already_shown=frozenset(seen) | hidden_people,
        in_context_since=history[0].created_at if history else None, now=now,
        reranker=judge, rng=deps.rng, names=names, probe=heard), None)
    if isinstance(judge, LLMJudge) and judge.usage is not None:
        jm = route.ledger_model or route.chat_model
        await _safe(archive.add_usage(pool, acc, day, jm, judge.usage, cost(judge.usage, jm)), None)
    if recall is not None:
        seen.update([m.id for m in recall.full] + [l.memory_id for l in recall.lines]
                    + [m.id for ms in recall.linked.values() for m in ms])
    state["recall_seen"] = sorted(seen)
    sticky = "" if scope.incognito else now_and_then(state, "sticky", await _safe(M.get_sticky(pool, comp), ""), now,
                                                     wake=bool(wake))
    core = [] if scope.incognito else [m.content for m in sorted(
        await _safe(M.list_memories(pool, comp, kind="core"), []), key=lambda m: m.id)]
    if recall is not None and (recall.full or recall.lines or recall.people):
        await emit({"type": "recall", "full": [m.content for m in recall.full],
                    "lines": [l.snippet for l in recall.lines], "people": [p.name for p in recall.people]})

    chat_info = lookup(route.chat_model)
    mode = monologue.effective_mode(settings, chat_info)
    if wake and mode == "monologue":
        head, _, rest = wake.partition("\n")          # 放在〔醒来〕那一行后面、最前面
        wake = f"{head}\n{monologue_note(lang, wake)}\n{rest}"
    character = persona.name if persona.custom(lang) else ""           # 自定义角色想事也得是它（10-01）
    english = lang == "zh" and mode == "native" and route.provider == "anthropic"   # Claude 用英文想，App 给翻译（10-01）
    last_thought = next((m.thinking for m in reversed(history) if m.role == "assistant"), "")
    lines = reminder_lines(settings, TurnFacts(turn_no, wake or text, last_assistant, list(state.get("last_tools", [])),
                                               last_thinking=last_thought),
                           deps.rng, no_draft=bool(chat_info and chat_info.drafts_in_thinking), mode=mode,
                           english=english, character=character)
    mono_rules = (monologue.rules(settings, settings.thinking_style_text.strip()
                                  or thinking_style(settings, character=character))
                  if mode == "monologue" else "")
    hist, tools_note = history_msgs(history, lang)
    before, thinking_lines = split_thinking(lines, settings)
    focus_note = "" if scope.incognito else await _safe(focus.pending_note(pool, conv, lang), "")
    if focus_note:                   # 哨兵：刚结束的专注，这一轮告诉它一次
        before = [*before, focus_note]
    lore_all = [] if scope.incognito else await _safe(lore.list_for(pool, acc, comp), [])
    if not scope.incognito:          # 标记表情：TA 给它哪句点了什么，这一轮告诉它一次
        before = [*before, *await _safe(reactions.pending_lines(pool, conv, lang), [])]
        near = "\n".join(await _safe(far_dates.open_lines(pool, comp, now, settings.tz, lang), []))
        if now_and_then(state, "dates", near, now, wake=bool(wake)):      # 快到的远事：不每轮都给（09-30）
            before = [*before, near]
        before = [*before, *await _safe(drawer.opened_lines(pool, comp, settings.tz, lang), [])]
        before = [*before, *await _safe(diary.unlocked_lines(pool, comp, lang), [])]   # 日记锁着那段 TA 打开了（10-01）
        wallet_note = await _safe(wallet.pending_note(pool, acc, now, lang), "")
        if wallet_note:              # 钱包（10-02 Tilia：偶尔提一句）：TA 自己记的、它还没听说的，隔半天才给一次
            before = [*before, wallet_note]
        tarot_note = await _safe(tarot.pending_note(pool, comp, lang), "")
        if tarot_note:               # 塔罗（10-03）：TA 抽、它解好的那局，下一次开口递一次
            before = [*before, tarot_note]
        food_note = "" if quiet_food else await _safe(food_store.pending_note(pool, acc, now, lang), "")
        if food_note:                # 饮食：TA 刚记的 / 刚估好的，这一轮告诉它一次（09-29）
            before = [*before, food_note]
        items = await _safe(context_line.load(pool, acc), {})
        listening = "" if wake else await _safe(ears.for_turn(pool, items, state, now, lang), "")
        if listening:                # 耳朵（09-30）：TA 说话时在放的歌；有它的这轮〔TA 那边〕不再写「在听」
            before = [*before, listening]
            items = {k: v for k, v in items.items() if k != "music"}
        reading = await _safe(books.reading_line(pool, acc, now, lang), "")
        if reading:                  # 书架（10-02）：TA 这 3 分钟里翻过页的那本
            before = [*before, reading]
        # 世界书（09-30）：TA 这句 + 上一句 + 它上一句里碰到关键词的；醒来只看 TA 最后一句
        prev_said = "" if wake else next((m.text for m in reversed(history) if m.role == "user"), "")
        book = lore.pick(lore_all, [text] if wake else [prev_said, text, last_assistant], state, turn_no, lang)
        if book:
            before = [*before, book]
        side = context_line.render(items, now, settings.tz, lang)
        if side and context_line.due(items, now, last_at=state.get("side_at"), last_key=state.get("side_key"),
                                     wake=bool(wake)):   # TA 那边：天气、在哪、日程、步数、快捷指令（09-28）；不是每轮都给
            before = [*before, side]
            state["side_at"], state["side_key"] = now.isoformat(), context_line.moment_key(items, now)
    outside = mcp.Toolbox()                      # 用户自己接的 MCP 服务（10-05，Host）：无痕不给；连不上的这一轮跳过
    if not scope.incognito and settings.mcp_servers:
        outside = await _safe(mcp.toolbox(pool, getattr(deps.keys, "box", None), acc, settings.mcp_servers), mcp.Toolbox())
    parts = ContextParts(
        tools=tool_specs(incognito=scope.incognito) + outside.specs,
        base=render_base(persona, core, lang, monologue=mono_rules,
                         tone=tone_lines(lang, settings.warmth, settings.initiative, settings.humor)
                         + ([] if scope.incognito else voice.mode_lines(lang, settings.voice_mode)),
                         relationship=settings.relationship, lore=lore.always_block(lore_all, lang),
                         chat_rules=not settings.long_mode,
                         life=settings.offline_life or settings.long_mode),   # 线下生活关着：没有出门吃饭那两行（10-05）     # 长文模式：拿掉「说话」那一节（10-01 Tilia）
        ledger=ledger.render_ledger(await archive.get_ledger(pool, conv), state.get("voice_samples", []), lang,
                                   settings.user_name),
        history=hist,
        volatile=render_volatile(now=now, tz=settings.tz, lang=lang, recall=recall, sticky=sticky, lines=before),
        user_text=with_tools_note(tools_note, wake or text_for_model),
        # 人设锚（10-01 Tilia：怕脱离人设）：离最新对话最近的一行，每轮十几个字
        tail="\n".join([*thinking_lines, TEXTS[lang]["anchor"].format(name=persona.name or "Lumi")
                         + ("" if settings.long_mode else TEXTS[lang]["short"])]),
        images=images,
    )
    req = build_request(parts, model=route.chat_model, thinking=mode == "native", user_tag=user_tag(acc),
                        lang=lang)
    await emit({"type": "injections", "lines": lines})
    await emit({"type": "typing"})

    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=comp, account_id=acc, now=now, lang=lang,
                      edit_ref=edit_ref, allowed=INCOGNITO_TOOLS if scope.incognito else None, tz=settings.tz,
                      names=names, deps=deps, mcp=outside.route)
    started = time.monotonic()                   # 「思考了 x 秒」：从开口到说完（含中间调工具）
    try:
        out = await tool_loop(adapter, req, ctx, emit, lang)
    except LLMError as e:
        await emit({"type": "error", "kind": e.kind,
                    "message": USER_ERRORS[lang].get(e.kind, USER_ERRORS[lang]["other"])})
        await archive.log_turn(pool, conv, {"turn": turn_no, "error": e.kind, "detail": e.message[:500],
                                            "wake": bool(wake)}, now=now)
        await emit({"type": "done"})
        return TurnOutcome(False, error=e.kind)

    thinking_ms = round((time.monotonic() - started) * 1000)
    usd = cost(out.usage, route.chat_model)
    await archive.add_usage(pool, acc, day, route.chat_model, out.usage, usd)
    keepalive.remember(scope, route, req, now, enabled=settings.cache_keepalive)   # Claude 缓存保活（09-29，开了才记）
    if wake:
        silent, out.text = split_silent(out.text)
        if silent:                   # 它选了不说：压着的动静全丢，聊天记录、状态都不动，只记这一轮花了多少
            await archive.log_turn(pool, conv, {"turn": turn_no, "wake": True, "silent": True, "model": route.chat_model,
                                                "tools": out.tools_used, "usage": asdict(out.usage), "cost_usd": usd,
                                                "thinking": out.thinking[-2000:]}, now=now)
            return TurnOutcome(False, usd or 0.0)
        emit = real_emit
        for ev in held:
            await emit(ev)
        await archive.add_message(pool, conv, "wake", wake, now=now)

    if out.thinking.strip():
        await emit({"type": "thinking", "text": out.thinking, "ms": thinking_ms})
    bubbles_out = split_reply(out.text, settings.max_bubbles, settings.long_mode)
    clip_ids: list = []
    for i, bubble in enumerate(bubbles_out):
        if i:
            await emit({"type": "typing"})
            await deps.sleep(typing_delay(bubble))
        if not voice.is_voice(bubble):
            await emit({"type": "bubble", "text": bubble})
            continue
        # 语音条（10-03）：念出来挂上；不发档 / 无痕 / 念不成 → 当文字发，存档里那段也改成文字
        clip = None
        if settings.voice_mode != "off" and not scope.incognito:
            near = lambda j: voice.strip_tags(voice.body(bubbles_out[j])) if 0 <= j < len(bubbles_out) else None
            try:
                clip = await voice.speak(deps, acc, text=voice.body(bubble), voice_id=settings.voice_id, purpose="note",
                                         prev=near(i - 1), nxt=near(i + 1))
            except voice.VoiceError as e:
                log.info("voice note fell back to text: %s", e.kind)
            except Exception:
                log.exception("voice note crashed; sent as text")
        if clip is None:
            out.text = out.text.replace(bubble, voice.as_text(bubble), 1)
            await emit({"type": "bubble", "text": voice.as_text(bubble)})
        else:
            clip_ids.append(clip.id)
            await emit({"type": "bubble", "text": voice.strip_tags(voice.body(bubble)), "voice": clip.public()})
    if not out.text.strip() and out.thinking.strip():
        log.warning("reply came out empty after cutting the monologue; thinking was: %s", out.thinking[-2000:])
    if out.text.strip():
        saved = await archive.add_message(pool, conv, "assistant", out.text, thinking=out.thinking,
                                          tools="\n".join(out.tool_notes), cards=out.cards, thinking_ms=thinking_ms,
                                          now=deps.now())
        await _safe(voice.attach(pool, acc, clip_ids, saved.id), None)
        if not wake and not scope.incognito:    # 「划线说两句」挂着线头：回话抄一份进页边（10-02 书架）
            await _safe(books.catch_reply(pool, acc, conv, comp, out.text, deps.now()), None)

    if recall is not None and out.text.strip():   # 浮上来的记忆，回复真用上了才算被想起（09-28 召回只读）
        await _safe(M.mark_used(pool, comp, [m.id for m in recall.full] + [l.memory_id for l in recall.lines]
                                + [m.id for ms in recall.linked.values() for m in ms],
                                out.text, names=names, now=now), [])
    state.update(turn_count=turn_no, last_tools=out.tools_used, last_prompt_tokens=out.last_prompt)
    await archive.save_state(pool, conv, state)
    await archive.log_turn(pool, conv, {
        "turn": turn_no, "model": route.chat_model,
        "recall": {"full": [m.id for m in recall.full], "lines": [l.memory_id for l in recall.lines],
                   "people": [p.id for p in recall.people]} if recall else None,
        "injections": lines, "tools": out.tools_used, "usage": asdict(out.usage), "cost_usd": usd,
        "prompt_total": out.last_prompt}, now=now)
    await emit({"type": "usage", **asdict(out.usage), "prompt_total": out.last_prompt, "cost_usd": usd,
                "today": await archive.usage_on(pool, acc, day)})

    info = lookup(route.chat_model)
    high_water = settings.memory_length or (info.high_water if info else DEFAULT_HIGH_WATER)
    if ledger.needs_roll(out.last_prompt, high_water):
        await roll(deps, scope, route, adapter, settings, state, parts, day, emit)
    if trial_mark is not None and out.text.strip():   # 醒来不说话的成本我们认（上面已经提前返回了）
        spent = (await archive.usage_on(pool, acc, day))["cost_usd"] - trial_mark
        await charge_trial(pool, acc, round(spent * 1_000_000))
    await emit({"type": "done"})
    return TurnOutcome(bool(out.text.strip()), usd or 0.0)


async def roll(deps: Deps, scope: Scope, route: Route, adapter, settings: Settings, state: dict,
               parts: ContextParts, day: date, emit: Emit) -> None:
    """卷账本：① 主模型先挑要长期记的（前缀跟刚才那轮一样，几乎全走缓存）② 便宜模型按天写新账
    ③ 超了天龄配额的天单独压 ④ 丢掉 14 天以前的、标记已卷、留腔调样本。
    写账失败：原文先留着，下一轮再试；连续失败提醒用户。账本只在这里动，平时不动，缓存不会无故作废。"""
    pool = deps.pool
    lang = settings.lang
    msgs = await archive.unrolled(pool, scope.conversation)
    plan = ledger.plan_roll(msgs)
    if not plan.rolled:
        return
    await emit({"type": "ledger", "status": "rolling", "count": len(plan.rolled)})

    pick_hist, pick_note = history_msgs(await files.decorate(pool, msgs, lang), lang)
    pick_parts = replace(parts, history=pick_hist, volatile="",
                         user_text=with_tools_note(pick_note, ledger.pick_prompt(plan.rolled, lang)))
    pick_req = build_request(pick_parts, model=route.chat_model, thinking=False, user_tag=user_tag(scope.account),
                             lang=lang)
    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=scope.companion, account_id=scope.account,
                      now=deps.now(), lang=lang)
    if not scope.incognito:          # 无痕里不记任何东西
        try:
            picked = await tool_loop(adapter, pick_req, ctx, emit, lang)
            await _account(pool, scope.account, day, route.chat_model, picked.usage)
        except LLMError as e:
            log.warning("pre-roll memory pick failed: %s", e)

    # 每种短活两条腿：先用便宜的，打回了换主聊天模型兜底；只有一个模型就给它两次机会（照之前自用的 App）
    def legs(first: str) -> list[str]:
        return [first, route.chat_model if first != route.chat_model else first]
    write_legs = legs(route.chat_model if settings.ledger_same_as_chat else route.ledger_model)
    age_legs = legs(route.chat_model if settings.ledger_same_as_chat else (route.age_model or route.ledger_model))
    name = Persona.from_dict(await archive.get_persona(pool, scope.companion), lang).name
    today = deps.now().astimezone(ZoneInfo(settings.tz)).date()
    days = await archive.get_ledger(pool, scope.conversation)
    stale = ledger.too_old(days, today)

    # ① 写新账：按天拆开，每天（太长就分段）单独写一小段接上去；任何一段写不出来 = 这次不卷
    ok = True
    for d, chunks in sorted(ledger.day_transcripts(plan.rolled, settings.tz, lang, settings.user_name).items()):
        if (today - d).days >= ledger.MAX_DAYS:
            continue                                   # 反正留不住，不花这个钱
        for transcript in chunks:
            entry, spent = await ledger.write_entry(adapter, write_legs, transcript, d, days.get(d, ""),
                                                    name=name, lang=lang, user_name=settings.user_name)
            for model, usage in spent:
                await _account(pool, scope.account, day, model, usage)
            if entry is None:
                ok = False
                break
            days[d] = ledger.join_text(days.get(d, ""), entry, lang)
        if not ok:
            break
    if not ok:
        state["ledger_fails"] = int(state.get("ledger_fails", 0)) + 1
        await archive.save_state(pool, scope.conversation, state)
        if state["ledger_fails"] >= LEDGER_FAIL_WARN:
            await emit({"type": "notice", "text": LEDGER_NOTICE[lang]})
        await emit({"type": "ledger", "status": "failed"})
        return

    # ② 压旧天：超了天龄配额的天单独压；压不动先留着，下次卷的时候再试
    for d, age, quota in ledger.over_quota(days, today, lang):
        short, spent = await ledger.age_day(adapter, age_legs, days[d], d, age, quota, name=name, lang=lang,
                                            user_name=settings.user_name)
        for model, usage in spent:
            await _account(pool, scope.account, day, model, usage)
        if short is not None:
            days[d] = short
    # ③ 14 天以前的丢掉（交给记忆库）
    for d in stale:
        days[d] = ""
    await archive.put_ledger(pool, scope.conversation, days, now=deps.now())
    await archive.mark_rolled(pool, scope.conversation, [m.id for m in plan.rolled])
    await edits.forget_up_to(pool, scope.conversation, plan.rolled[-1].id)
    state["voice_samples"] = ledger.voice_samples(plan.rolled)
    state["ledger_fails"] = 0
    state["recall_seen"] = []            # 新的一潮：原文卷走了，靠联想的记忆可以重新浮上来
    state["lore_seen"] = {}              # 世界书也清零：递过的那几轮卷走了
    await archive.save_state(pool, scope.conversation, state)
    await emit({"type": "ledger", "status": "done", "count": len(plan.rolled)})
