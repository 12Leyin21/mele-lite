"""聊天：发消息进等候区、事件流、补拉、倒回。"""
from __future__ import annotations

import asyncio
import json
from datetime import date, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response
from fastapi.responses import StreamingResponse

from brain import accounts, archive, attachments, books, reactions, rewind
from brain import voice
from brain.bubbles import split_reply
from brain.scope import Scope
from brain.settings import Settings
from brain.turn import run_turn
from patrol import store as patrol_store

from .deps import Api, account, api, own_conversation

router = APIRouter()
KEEPALIVE = 15.0                 # 事件流没事件时隔多久发一行心跳，免得被中间的代理掐断


def _runner(a: Api, scope: Scope):
    async def run(text: str, resend: bool, emit, attachments: list, parts: list) -> None:
        out = await run_turn(a.deps, scope, text, emit, resend=resend, attachments=attachments, pieces=parts)
        await accounts.touch_conversation(a.deps.pool, scope.conversation, a.deps.now())
        if out.said and not scope.incognito:
            reply = next((m for m in reversed(await archive.recent(a.deps.pool, scope.conversation, 3))
                          if m.role == "assistant"), None)
            if reply is not None:
                if not a.rooms.watched(scope.conversation):     # TA 发完就切走了：它的回话推送过去（09-28）
                    await patrol_store.queue_push(a.deps.pool, account=scope.account, companion=scope.companion,
                                                  conversation=scope.conversation, text=reply.text)
    return run


@router.post("/conversations/{conv}/messages", status_code=202)
async def send(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """发一句：先进等候区，安静满 reply_wait 秒才跑。回复从 /events 推。
    client_id 是 app 自己生成的：30 秒没收到这一轮的事件就带同一个 id 重发，这里不会排两次。"""
    scope = await own_conversation(a, acc, conv)
    text = str(body.get("text") or "").strip()
    try:
        files = [UUID(str(x)) for x in body.get("attachments") or []][:10]
    except ValueError:
        raise HTTPException(400, "附件编号不对") from None
    if not text and not files:
        raise HTTPException(400, "说点什么吧")
    wait = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion)).reply_wait
    client_id = str(body["client_id"]) if body.get("client_id") else None
    if body.get("book_mark_id"):     # 「划线说两句」（10-02 书架）：它接下来的回话抄一份进页边
        await books.arm_thread(a.deps.pool, acc, conv, int(body["book_mark_id"]), a.deps.now())
    elif text:                       # 说了别的就收线
        await books.disarm(a.deps.pool, conv)
    queued = a.rooms.submit(conv, text, client_id, wait, _runner(a, scope), files)
    return {"queued": queued, "client_id": client_id, "reply_wait": wait}


@router.get("/conversations/{conv}/events")
async def events(conv: UUID, request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    """一直连着的事件流（Server-Sent Events）。同一个窗口可以有好几个连着的（手机 + 平板）。"""
    await own_conversation(a, acc, conv)
    q = a.rooms.listen(conv)

    async def stream():
        try:
            yield ": hello\n\n"
            while True:
                try:
                    ev = await asyncio.wait_for(q.get(), KEEPALIVE)
                except asyncio.TimeoutError:
                    if await request.is_disconnected():
                        return
                    yield ": ping\n\n"
                    continue
                if ev is None:           # 窗口删了
                    return
                yield f"data: {json.dumps(ev, ensure_ascii=False, default=str)}\n\n"
        finally:
            a.rooms.unlisten(conv, q)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def _msg(m: archive.StoredMsg) -> dict:
    return {"id": m.id, "role": m.role, "text": m.text, "thinking": m.thinking, "thinking_ms": m.thinking_ms,
            "at": m.created_at.isoformat()}


@router.get("/conversations/{conv}/messages")
async def messages(conv: UUID, after: int = 0, before: int | None = None, day: str | None = None, limit: int = 200,
                   acc: UUID = Depends(account), a: Api = Depends(api)):
    """三种取法：after = 补拉（app 从后台回来，拉 after 之后没看到的，含思考链）；before = 往前翻（上滑加载更早的）；
    day = YYYY-MM-DD 那天的（按联系人时区，「回到那天」）。〔醒来〕是给它看的，一律不给。
    busy=true 表示还有排着或者正在跑的一轮，app 可以接着等事件流。"""
    scope = await own_conversation(a, acc, conv)
    limit = max(1, min(limit, 500))
    has_more = None
    if before is not None:
        msgs, has_more = await archive.before(a.deps.pool, conv, before, limit)
    elif day is not None:
        try:
            d = date.fromisoformat(day)
        except ValueError:
            raise HTTPException(400, "day 要写成 2026-09-27") from None
        tz = ZoneInfo(Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion)).tz)
        start = datetime.combine(d, time(0), tzinfo=tz)
        msgs = await archive.between(a.deps.pool, conv, start, start + timedelta(days=1), limit)
    else:
        msgs = await archive.after(a.deps.pool, conv, after, limit)
    shown = [m for m in msgs if m.role != "wake"]
    settings = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))

    def bubbles(m: archive.StoredMsg) -> list[str]:       # 跟事件流里推的一样切；TA 连发的几句还原成几个
        if m.role == "assistant":
            return split_reply(m.text, settings.max_bubbles, settings.long_mode)
        return m.parts or [m.text]
    marks = await reactions.for_messages(a.deps.pool, [m.id for m in shown])
    files = await attachments.for_messages(a.deps.pool, [m.id for m in shown])
    clips = {m.id: await voice.clips_for_message(a.deps.pool, scope.account, m.id)
             for m in shown if m.role == "assistant" and voice.MARK in m.text}

    def with_voice(m: archive.StoredMsg) -> tuple[list[str], list]:
        """语音条（10-03）：气泡里给逐字稿，并排一列 voices（null = 文字），App 老版本照样读 bubbles。"""
        bs = bubbles(m)
        if m.id not in clips:
            return bs, [None] * len(bs)
        texts, vs = [], []
        for b in bs:
            c = clips[m.id].get(voice.text_sha(voice.body(b))) if voice.is_voice(b) else None
            texts.append(voice.strip_tags(voice.body(b)) if voice.is_voice(b) else b)
            vs.append(c.public() if c else None)
        return texts, vs
    shaped = {m.id: with_voice(m) for m in shown}
    out = {"messages": [{**_msg(m), "bubbles": shaped[m.id][0], "voices": shaped[m.id][1], "cards": m.cards or [],
                         "reaction": marks.get(m.id),
                         "attachments": [f.public() for f in files.get(m.id, [])]} for m in shown],
           "busy": a.rooms.busy(conv)}
    if has_more is not None:
        out["has_more"] = has_more
    return out


@router.get("/conversations/{conv}/calendar")
async def calendar(conv: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """聊天日历：哪几天聊过（按联系人时区）、那天说了几句、那天第一句的号（点日期从那句开始看）。〔醒来〕不算。"""
    scope = await own_conversation(a, acc, conv)
    tz = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion)).tz
    rows = await a.deps.pool.fetch(
        "SELECT to_char(created_at AT TIME ZONE $2, 'YYYY-MM-DD') AS day, count(*) AS n, min(id) AS first_id "
        "FROM chat_messages WHERE user_id = $1 AND role <> 'wake' GROUP BY 1 ORDER BY 1", conv, tz)
    return {"days": [{"day": r["day"], "count": r["n"], "first_id": r["first_id"]} for r in rows]}


@router.get("/conversations/{conv}/search")
async def search(conv: UUID, q: str = "", limit: int = 50, acc: UUID = Depends(account), a: Api = Depends(api)):
    """按字搜聊天记录（只搜说出口的话，不搜思考链），新的在前；每条带前后各一条当上下文，点了跳过去用 before / after 补。"""
    await own_conversation(a, acc, conv)
    q = q.strip()
    if not q:
        raise HTTPException(400, "要搜什么？")
    hits = []
    for m in await archive.search(a.deps.pool, conv, q[:100], max(1, min(limit, 100))):
        prev, nxt = await archive.neighbours(a.deps.pool, conv, m.id)
        hits.append({"message": _msg(m), "before": _msg(prev) if prev else None, "after": _msg(nxt) if nxt else None})
    return {"hits": hits}


@router.post("/conversations/{conv}/rewind")
async def do_rewind(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """点用户的一句 → 这句和之后的撤回，原文还给输入栏（kind=edit）；
    点它一轮的最后一条 → 撤回这一轮回复，服务器接着自己重新回（kind=regenerate，事件照样从 /events 推）。"""
    scope = await own_conversation(a, acc, conv)
    if a.rooms.busy(conv):
        raise HTTPException(409, "它还在回，等这一轮说完再倒回")
    try:
        mid = int(body["message_id"])
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "要带 message_id") from None
    role = next((m.role for m in await archive.unrolled(a.deps.pool, conv) if m.id == mid), None)
    try:
        if role == "user":
            return {"kind": "edit", "text": await rewind.rewind_to_user(a.deps.pool, a.deps.embedder, scope, mid)}
        await rewind.undo_reply(a.deps.pool, a.deps.embedder, scope, mid)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    a.rooms.run_now(conv, _runner(a, scope), resend=True)
    return {"kind": "regenerate"}


@router.put("/messages/{mid}/reaction", status_code=204)
async def react(mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """给它的一句点个表情（一条一个，再点就换）。只能点它说的话。"""
    conv, role = await _owned_message(a, acc, mid)
    emoji = str(body.get("emoji") or "").strip()
    if not emoji or len(emoji) > 16:
        raise HTTPException(400, "要带一个表情")
    if role != "assistant":
        raise HTTPException(400, "只能给它说的话点表情")
    await reactions.set_reaction(a.deps.pool, conv, mid, emoji)
    return Response(status_code=204)


@router.delete("/messages/{mid}/reaction", status_code=204)
async def unreact(mid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    conv, _ = await _owned_message(a, acc, mid)
    await reactions.set_reaction(a.deps.pool, conv, mid, None)
    return Response(status_code=204)


@router.post("/messages/{mid}/thinking/translate")
async def translate_thinking(mid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    """它那句的思考链翻成中文（10-01）：翻过的直接给。"""
    from brain.auth import TrialOver
    from brain.translate import thinking_zh
    conv, role = await _owned_message(a, acc, mid)
    r = await a.deps.pool.fetchrow("SELECT m.thinking, c.companion_id FROM chat_messages m JOIN conversations c "
                                   "ON c.id = m.user_id WHERE m.id = $1", mid)
    if role != "assistant" or not (r["thinking"] or "").strip():
        raise HTTPException(400, "这句没有思考链")
    try:
        text = await thinking_zh(a.deps, Scope(acc, r["companion_id"], conv), mid, r["thinking"], a.deps.now())
    except TrialOver:
        raise HTTPException(402, "今天的免费额度用完了")
    return {"text": text}


async def _owned_message(a: Api, acc: UUID, mid: int) -> tuple[UUID, str]:
    r = await a.deps.pool.fetchrow("SELECT user_id, role FROM chat_messages WHERE id = $1", mid)
    if r is None:
        raise HTTPException(404, "没有这条消息")
    await own_conversation(a, acc, r["user_id"])          # 不是这个账号的窗口 → 404
    return r["user_id"], r["role"]
