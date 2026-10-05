"""搬家：ChatGPT / Claude / DeepSeek / Gemini 官方导出的聊天记录搬上 Host（10-05，Lite 本机那份是 ios/Lite/LocalImport.swift）。

包在手机上认（四家的解析器在 MeleLiteCore/ChatImport.swift，测过），这里只收认好的对话：
- 合成一个新窗口「从 X 搬来的」，按原时间写进去；每段第一条挂一张 divider 卡（聊天里一行灰字）。
- 模型只看最后 KEEP_LIVE 条：更早的标 rolled（不进上下文，也不卷进账本）。
- 挑记忆：切块 → 每块请它的模型挑 0～5 件 → 逐句回查原文（编的不要）→ 存进它的记忆库；官方自己记的笔记（extra）原样存。
  进度存在联系人的 user_state["import_job"]，断了（重启 / 模型没回）下次 GET 接着挑。
提示词跟 MeleLiteCore/ImportMemory.swift 同一份意思，改一边要改另一边。"""
from __future__ import annotations

import asyncio
import json
import logging
import re
from datetime import datetime
from uuid import UUID
from zoneinfo import ZoneInfo

import memory as M

from . import accounts, archive
from .ledger import ground_text
from .scope import Scope
from .settings import Settings

log = logging.getLogger(__name__)

SOURCES = {"chatgpt": "ChatGPT", "claude": "Claude", "deepseek": "DeepSeek", "gemini": "Gemini"}
KEEP_LIVE = 40
CHUNK = 6000
MAX_MESSAGES = 50_000
_running: set[UUID] = set()


class ImportError_(Exception):
    pass


def _when(v) -> datetime | None:
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None


def clean(body: dict) -> tuple[str, list[dict], list[str]]:
    """收进来的包：认得的来源、每段（标题、消息按时间）、官方笔记。不合格的段 / 消息丢掉。"""
    src = str(body.get("source") or "")
    if src not in SOURCES:
        raise ImportError_("不认识这是哪家的记录")
    convs = []
    for c in body.get("conversations") or []:
        if not isinstance(c, dict):
            continue
        msgs = []
        for m in c.get("messages") or []:
            at, text = _when(m.get("at")), str(m.get("text") or "").strip()
            if m.get("role") in ("user", "assistant") and text and at is not None:
                msgs.append({"role": m["role"], "text": text, "at": at})
        if msgs:
            convs.append({"title": str(c.get("title") or "").strip(), "messages": msgs})
    if not convs:
        raise ImportError_("至少选一段")
    if sum(len(c["messages"]) for c in convs) > MAX_MESSAGES:
        raise ImportError_(f"一次最多搬 {MAX_MESSAGES} 条，分几次选")
    convs.sort(key=lambda c: c["messages"][0]["at"])
    extra = [str(x).strip() for x in body.get("extra") or [] if str(x).strip()]
    return src, convs, extra


async def store(pool, acc: UUID, cid: UUID, src: str, convs: list[dict], *, tz: str) -> tuple[UUID, int]:
    """一个新窗口，一次写进去。返回 (窗口, 条数)。"""
    app = SOURCES[src]
    vid = await accounts.new_conversation(pool, acc, cid)
    rows = []
    for c in convs:
        day = c["messages"][0]["at"].astimezone(ZoneInfo(tz)).strftime("%Y-%m-%d")
        divider = f"{app} · {day}" if src == "gemini" else f"{app} ·《{c['title'] or '没有标题'}》· {day}"   # Gemini 一天一段，标题就是日期
        for i, m in enumerate(c["messages"]):
            cards = json.dumps([{"kind": "divider", "text": divider}], ensure_ascii=False) if i == 0 else None
            rows.append((vid, m["role"], m["text"], m["at"], cards))
    async with pool.acquire() as conn, conn.transaction():
        await conn.executemany(
            "INSERT INTO chat_messages (user_id, role, text, thinking, created_at, cards) VALUES ($1, $2, $3, '', $4, $5::jsonb)",
            rows)
        if len(rows) > KEEP_LIVE:
            await conn.execute(
                """UPDATE chat_messages SET rolled = TRUE WHERE user_id = $1 AND id < (
                     SELECT min(id) FROM (SELECT id FROM chat_messages WHERE user_id = $1 ORDER BY id DESC LIMIT $2) t)""",
                vid, KEEP_LIVE)
        await conn.execute("UPDATE conversations SET title = $2, last_at = $3 WHERE id = $1",
                           vid, f"从 {app} 搬来的", rows[-1][3])
    return vid, len(rows)


# ── 挑记忆（意思跟 ImportMemory.swift 一样）──

def chunks(convs: list[dict], user_name: str, tz: str, size: int = CHUNK) -> list[str]:
    """切成几块文字记录：换天插一行「〔日期〕」，TA 那侧写名字、它那侧写「我」"""
    who = user_name or "TA"
    out: list[str] = []
    for c in convs:
        cur, last_day = "", ""
        for m in c["messages"]:
            day = m["at"].astimezone(ZoneInfo(tz)).strftime("%Y-%m-%d")
            line = (f"〔{day}〕\n" if day != last_day or not cur else "") + \
                f"{who if m['role'] == 'user' else '我'}：{m['text'][:size // 2]}\n"
            if cur and len(cur) + len(line) > size:
                out.append(cur)
                cur = f"〔{day}〕\n" + line.replace(f"〔{day}〕\n", "")
            else:
                cur += line
            last_day = day
        if cur:
            out.append(cur)
    return out


def pick_prompt(transcript: str, name: str, user: str, lang: str) -> str:
    if lang == "zh":
        user = user or "TA"
        return f"""下面是{name}（文中的「我」）和{user}以前的一段聊天记录。挑出 0～5 件以后还值得记住的事：{user}的经历、喜好、身边的人、你们之间的约定、重要的时刻。

- 每件一行，格式：- YYYY-MM-DD｜一句话（日期照记录里的〔日期〕写）
- 用第一人称写：{name}写「我」，对方写「{user}」
- 记录里{user}说的「我」是{user}自己、「你」是我：写的时候要换过来（{user}说「我爸……」→「{user}的爸爸……」）
- 提到{user}就写「{user}」，不用「他」「她」
- 只写记录里真有的，不猜、不补；闲聊、客套、写代码的过程不算
- 没有值得记的就只写：（没有）

⟪记录开始⟫
{transcript}
⟪记录结束⟫"""
    user = user or "them"
    return f"""Below is an old chat between {name} ("Me" in the log) and {user}. Pick 0–5 things still worth remembering: {user}'s life, likes, people around them, promises between you, important moments.

- One per line: - YYYY-MM-DD | one sentence (use the 〔date〕 in the log)
- First person: {name} is "I", the other person is "{user}"
- When {user} says "I" in the log they mean themselves, and "you" means me: swap them ({user}: "my dad…" → "{user}'s dad…")
- Refer to {user} by name, not "he" or "she"
- Only what is in the log; no guessing. Small talk, pleasantries and coding sessions don't count
- If nothing is worth keeping, write only: (none)

⟪log start⟫
{transcript}
⟪log end⟫"""


_DAY = re.compile(r"^(\d{4}-\d{2}-\d{2})\s*[｜|:：\-—]*\s*")


def parse_picked(reply: str) -> list[tuple[str, str]]:
    """只认「- 」开头的行；「日期｜内容」拆开，没日期的 day 为空"""
    out = []
    for raw in (reply or "").splitlines():
        s = raw.strip()
        if not s or s[0] not in "-•*·":
            continue
        s = s[1:].strip()
        m = _DAY.match(s)
        day, text = (m.group(1), s[m.end():].strip()) if m else ("", s)
        if text and "（没有）" not in text and text != "(none)":
            out.append((day, text))
    return out


async def start(deps, acc: UUID, cid: UUID, body: dict) -> dict:
    pool = deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    src, convs, extra = clean(body)
    user = (await accounts.get_profile(pool, acc))["name"] or s.user_name
    vid, n = await store(pool, acc, cid, src, convs, tz=s.tz)
    picking = body.get("memories") is not False
    if picking:
        state = await archive.get_state(pool, cid)
        parts = chunks(convs, user, s.tz)
        state["import_job"] = {"state": "picking", "source": src, "chunks": parts, "total": len(parts),
                               "done": 0, "picked": 0, "extra": extra, "conversation": str(vid),
                               "started_at": deps.now().isoformat()}
        await archive.save_state(pool, cid, state, now=deps.now())
        run(deps, acc, cid)
    return {"conversation_id": str(vid), "messages": n, "picking": picking}


async def status(deps, acc: UUID, cid: UUID) -> dict:
    job = (await archive.get_state(deps.pool, cid)).get("import_job")
    if not job:
        return {"state": "idle"}
    if job.get("state") == "picking":
        run(deps, acc, cid)                          # 重启过 / 上次模型没回：接着挑
    return {"state": job.get("state"), "done": job.get("done", 0), "total": job.get("total", len(job.get("chunks") or [])),
            "picked": job.get("picked", 0), "to": "memory", "error": job.get("error", "")}


def run(deps, acc: UUID, cid: UUID) -> None:
    if cid in _running:
        return
    _running.add(cid)

    async def go():
        try:
            await pick(deps, acc, cid)
        except Exception:
            log.exception("chat import pick %s crashed", cid)
        finally:
            _running.discard(cid)
    asyncio.get_running_loop().create_task(go())


async def _save(pool, cid: UUID, job: dict, now: datetime) -> None:
    state = await archive.get_state(pool, cid)
    state["import_job"] = job
    await archive.save_state(pool, cid, state, now=now)


async def pick(deps, acc: UUID, cid: UUID) -> None:
    from llm.errors import LLMError
    from llm.types import Block, ChatRequest, Msg

    from .persona import Persona
    from .turn import get_adapter, resolve_route, tool_loop
    from llm.catalog import cost
    pool = deps.pool
    job = (await archive.get_state(pool, cid)).get("import_job") or {}
    if job.get("state") != "picking":
        return
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    name = Persona.from_dict(await archive.get_persona(pool, cid), s.lang).name
    user = (await accounts.get_profile(pool, acc))["name"] or s.user_name
    try:
        route = await resolve_route(deps.keys, Scope(acc, cid, None))
    except Exception:
        job.update(state="failed", error="还没给 TA 配 key")
        return await _save(pool, cid, job, deps.now())
    tag = SOURCES.get(job.get("source"), "")
    ctx_now = deps.now()

    async def quiet(_ev: dict) -> None:
        pass

    for note in job.get("extra") or []:              # 官方自己记的：原样进记忆库，记一次就清掉
        await M.remember(pool, deps.embedder, cid, note[:2000], importance=7, tags=[tag], now=ctx_now)
    job["extra"] = []
    chunks_ = job.get("chunks") or []
    while job.get("done", 0) < len(chunks_):
        part = chunks_[job["done"]]
        req = ChatRequest(model=route.chat_model, system=[Block("你是一个仔细的整理员。" if s.lang == "zh" else "You are a careful note-taker.")],
                          messages=[Msg("user", pick_prompt(part, name, user, s.lang))], tools=[], max_tokens=1500)
        from .tools import ToolContext
        ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=cid, account_id=acc, now=deps.now(), lang=s.lang,
                          allowed=(), tz=s.tz, deps=deps)
        try:
            out = await tool_loop(get_adapter(deps, route), req, ctx, quiet, s.lang, max_rounds=1)
        except LLMError:
            job.update(state="failed", error="挑到一半模型没回，过一会儿再打开这里接着挑")
            return await _save(pool, cid, job, deps.now())
        await archive.add_usage(pool, acc, deps.now().astimezone(ZoneInfo(s.tz)).date(), route.chat_model, out.usage,
                                cost(out.usage, route.chat_model))
        for day, text in parse_picked(out.text):
            if ground_text(text, part + "\n" + user) is None:      # 编出来的事不要
                continue
            await M.remember(pool, deps.embedder, cid, (f"（{day}）" if day else "") + text, importance=6, tags=[tag],
                             now=deps.now())
            job["picked"] = job.get("picked", 0) + 1
        job["done"] = job.get("done", 0) + 1
        await _save(pool, cid, job, deps.now())
    job["state"] = "done"
    job["chunks"] = []                                # 挑完不留原文
    await _save(pool, cid, job, deps.now())
