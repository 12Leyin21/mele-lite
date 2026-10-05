"""测试网页的接口。/api/chat 把一轮里的事件（正在输入、气泡、思考链、小卡片、用量……）一条条推给页面。"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import date, timedelta
from pathlib import Path
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse

import memory as M
from brain import accounts, archive, drawer, far_dates, ledger, rewind
from brain.persona import Persona, persona_cost, render_base
from brain.settings import Settings
from brain.tools import tool_specs
from brain.scope import Scope
from brain.turn import Deps, get_adapter, run_turn
from api.rooms import Rooms
from llm.cachecheck import cache_check
from patrol import store as clock_store
from patrol.clocks import next_fire, patrol_numbers, validate_spec
from patrol.estimate import levels_table
from patrol.loop import patrol_loop, tick_once
from patrol.wake import record, wake_turn

log = logging.getLogger(__name__)
STATIC = Path(__file__).with_name("static")


def create_app(deps: Deps, scope: Scope | UUID) -> FastAPI:
    """测试台：一个账号，当前在哪个联系人的哪个窗口放在 cur 里（以后页面上能切）。
    设置、人设、记忆、便利贴归联系人；聊天、账本、状态归窗口；人物卡、用量、钥匙归账号（brain/scope.py）。"""
    app = FastAPI(title="new-app 测试台")
    cur = {"scope": Scope.of(scope), "offset": timedelta(0), "loop": None}
    real_now = deps.now
    deps.now = lambda: real_now() + cur["offset"]       # 巡逻栏的「拨快时间」：整个测试台（聊天、巡逻）一起拨
    rooms = Rooms()                                    # 测试台的聊天不走等候区，这个只给巡逻判断「忙不忙」

    def sc() -> Scope:
        return cur["scope"]

    async def settings() -> Settings:
        return Settings.from_dict(await archive.get_settings(deps.pool, sc().companion))

    @app.get("/")
    async def index():
        return FileResponse(STATIC / "index.html")

    @app.post("/api/chat")
    async def chat(body: dict = Body(...)):
        text = str(body.get("text") or "").strip()
        resend = bool(body.get("resend"))
        if not text and not resend:
            raise HTTPException(400, "text is empty")
        queue: asyncio.Queue = asyncio.Queue()

        async def emit(ev: dict) -> None:
            await queue.put(ev)

        async def runner() -> None:
            try:
                await run_turn(deps, sc(), text, emit, resend=resend)
                await accounts.touch_conversation(deps.pool, sc().conversation, deps.now())
            except Exception as e:  # 服务器自己的 bug 也要让页面知道，别让它一直转圈
                log.exception("turn crashed")
                await queue.put({"type": "error", "kind": "server", "message": f"服务器出错：{e}"})
                await queue.put({"type": "done"})
            finally:
                await queue.put(None)

        task = asyncio.create_task(runner())

        async def stream():
            while (ev := await queue.get()) is not None:
                yield f"data: {json.dumps(ev, ensure_ascii=False, default=str)}\n\n"
            await task

        return StreamingResponse(stream(), media_type="text/event-stream")

    @app.get("/api/state")
    async def state():
        s = await settings()
        persona = Persona.from_dict(await archive.get_persona(deps.pool, sc().companion), s.lang)
        st = await archive.get_state(deps.pool, sc().conversation)
        unrolled = {m.id for m in await archive.unrolled(deps.pool, sc().conversation)}
        route = deps.keys.route_for(sc().account)
        day = deps.now().astimezone(ZoneInfo(s.tz)).date()
        return {
            "settings": s.to_dict(),
            "persona": persona.to_dict(),
            "model": {"provider": route.provider, "chat": route.chat_model, "ledger": route.ledger_model,
                      "age": route.age_model or route.ledger_model},
            "ledger": ledger.render_ledger(await archive.get_ledger(deps.pool, sc().conversation),
                                           st.get("voice_samples", []), s.lang, s.user_name),
            "sticky": await M.get_sticky(deps.pool, sc().companion),
            "usage_today": await archive.usage_on(deps.pool, sc().account, day),
            "history": [{"id": m.id, "role": m.role, "text": m.text, "thinking": m.thinking,
                         "at": m.created_at.isoformat(), "rolled": m.id not in unrolled}
                        for m in await archive.recent(deps.pool, sc().conversation, 100)],
            "where": await where(),
        }

    @app.put("/api/settings")
    async def put_settings(body: dict = Body(...)):
        try:
            s = Settings.from_dict(body)
        except (ValueError, TypeError) as e:
            raise HTTPException(400, str(e)) from e
        await archive.save_settings(deps.pool, sc().companion, s.to_dict())
        return s.to_dict()

    @app.put("/api/persona")
    async def put_persona(body: dict = Body(...)):
        s = await settings()
        try:
            p = Persona.from_dict(body, s.lang)
        except TypeError as e:
            raise HTTPException(400, str(e)) from e
        await archive.save_persona(deps.pool, sc().companion, p.overrides(s.lang))   # 只存改过的，出厂改了能跟上
        route = deps.keys.route_for(sc().account)
        return {"persona": p.to_dict(),
                "import_cost_usd": persona_cost(p.imported, route.chat_model) if p.imported.strip() else None}

    @app.get("/memories")
    async def memories_page():
        return FileResponse(STATIC / "memories.html")

    @app.get("/api/memories")
    async def memories():
        """调试页：她记下的一切，包括 TA 看不到的「关于 TA」——正式 app 里不会有这个口子。"""
        mems = await M.list_memories(deps.pool, sc().companion, include_hidden=True, limit=1000)
        people = await M.list_people(deps.pool, sc().account)
        days = await archive.get_ledger(deps.pool, sc().conversation)
        return {
            "memories": [m.to_dict() for m in mems if m.kind != "person"],
            "people": [p.to_dict() for p in people],
            "sticky": await M.get_sticky(deps.pool, sc().companion),
            "ledger": [{"day": d.isoformat(), "text": t} for d, t in days.items()],
        }

    @app.delete("/api/memories/{memory_id}")
    async def delete_memory(memory_id: int):
        return {"deleted": await M.delete(deps.pool, sc().companion, memory_id)
                or await M.delete(deps.pool, sc().account, memory_id)}      # 人物卡在账号名下

    @app.post("/api/cache-check")
    async def check():
        s = await settings()
        route = deps.keys.route_for(sc().account)
        persona = Persona.from_dict(await archive.get_persona(deps.pool, sc().companion), s.lang)
        return await cache_check(get_adapter(deps, route), route.chat_model,
                                 render_base(persona, [], s.lang, relationship=s.relationship), tool_specs())

    # ── 联系人 / 窗口 / 无痕 / 倒回（09-27 Tilia加的，测试台先有，正式接口第 4 步做） ──

    async def where() -> dict:
        s = sc()
        comps = []
        for cid in await accounts.list_companions(deps.pool, s.account):
            st = Settings.from_dict(await archive.get_settings(deps.pool, cid))
            comps.append({"id": str(cid), "name": Persona.from_dict(await archive.get_persona(deps.pool, cid), st.lang).name})
        convs = []
        for c in await accounts.list_conversations(deps.pool, s.account, s.companion):
            first = next(iter(await archive.recent(deps.pool, c.id, 1)), None)
            convs.append({"id": str(c.id), "at": c.last_at.isoformat(), "last": first.text[:24] if first else ""})
        return {"companion": str(s.companion), "conversation": str(s.conversation), "incognito": s.incognito,
                "companions": comps, "conversations": convs}

    async def latest_window(companion: UUID) -> UUID:
        convs = await accounts.list_conversations(deps.pool, sc().account, companion)
        return convs[0].id if convs else await accounts.new_conversation(deps.pool, sc().account, companion)

    @app.post("/api/companions")
    async def add_companion(body: dict = Body(default={})):
        if sc().incognito:
            raise HTTPException(400, "先关掉无痕")
        cid = await accounts.create_companion(deps.pool, sc().account)
        name = str(body.get("name") or "").strip()
        s = Settings.from_dict({"tz": (await settings()).tz})
        await archive.save_settings(deps.pool, cid, s.to_dict())
        if name:
            await archive.save_persona(deps.pool, cid, {"name": name})
        conv = await accounts.new_conversation(deps.pool, sc().account, cid)
        cur["scope"] = Scope(sc().account, cid, conv)
        return await where()

    @app.post("/api/switch")
    async def switch(body: dict = Body(...)):
        """换联系人（到它最近的窗口）或换窗口。无痕开着不能换。"""
        if sc().incognito:
            raise HTTPException(400, "先关掉无痕")
        if body.get("conversation"):
            cur["scope"] = await accounts.scope_for(deps.pool, sc().account, UUID(body["conversation"]))
        elif body.get("companion"):
            comp = UUID(body["companion"])
            if comp not in await accounts.list_companions(deps.pool, sc().account):
                raise HTTPException(404, "没有这个联系人")
            cur["scope"] = Scope(sc().account, comp, await latest_window(comp))
        return await where()

    @app.post("/api/conversations")
    async def new_window():
        if sc().incognito:
            raise HTTPException(400, "先关掉无痕")
        conv = await accounts.new_conversation(deps.pool, sc().account, sc().companion)
        cur["scope"] = Scope(sc().account, sc().companion, conv)
        return await where()

    @app.post("/api/incognito")
    async def incognito(body: dict = Body(...)):
        on = bool(body.get("on"))
        if on and not sc().incognito:
            cur["back"] = sc()
            cur["scope"] = await rewind.start_incognito(deps.pool, sc().account, sc().companion)
        elif not on and sc().incognito:
            await rewind.end_incognito(deps.pool, sc())
            cur["scope"] = cur.pop("back")
        return await where()

    @app.post("/api/rewind")
    async def do_rewind(body: dict = Body(...)):
        """点用户的一句 → 撤回这句和之后的，原文还给输入栏（kind=edit）；
        点它一轮的最后一条 → 撤回这一轮回复，页面接着用 /api/chat {resend: true} 让它重新回（kind=regenerate）。"""
        mid = int(body["message_id"])
        role = next((m.role for m in await archive.unrolled(deps.pool, sc().conversation) if m.id == mid), None)
        try:
            if role == "user":
                return {"kind": "edit", "text": await rewind.rewind_to_user(deps.pool, deps.embedder, sc(), mid)}
            await rewind.undo_reply(deps.pool, deps.embedder, sc(), mid)
            return {"kind": "regenerate"}
        except ValueError as e:
            raise HTTPException(400, str(e)) from e

    # ── 巡逻栏（09-27）：看所有的钟（含它偷偷约的）、现在叫醒它、拨快时间、跑一圈、醒来账 ──

    @app.get("/api/patrol")
    async def patrol_state():
        s = sc()
        st = await settings()
        clocks = await clock_store.list_clocks(deps.pool, s.account, s.companion, kinds=("user", "self", "heartbeat", "date"))
        rows = await deps.pool.fetch("SELECT at, reason, outcome, cost_usd FROM wake_log WHERE companion_id = $1 "
                                     "ORDER BY at DESC LIMIT 40", s.companion)
        avg = await deps.pool.fetchval("SELECT avg(cost_usd) FROM wake_log WHERE companion_id = $1 "
                                       "AND outcome IN ('said', 'silent') AND cost_usd > 0", s.companion)
        model = deps.keys.route_for(s.account).chat_model
        return {
            "now": deps.now().isoformat(), "offset_hours": cur["offset"].total_seconds() / 3600,
            "loop_on": cur["loop"] is not None, "numbers": patrol_numbers(st).__dict__,
            "clocks": [{"id": c.id, "kind": c.kind, "shape": c.shape, "spec": c.spec, "note": c.note,
                        "next_at": c.next_at.isoformat() if c.next_at else None} for c in clocks],
            "wakes": [{"at": r["at"].isoformat(), "reason": r["reason"], "outcome": r["outcome"],
                       "cost_usd": r["cost_usd"]} for r in rows],
            "estimate": levels_table(model, avg, st.sleep_from, st.sleep_to),
        }

    @app.post("/api/patrol/clock")
    async def patrol_add_clock(body: dict = Body(...)):
        s, st = sc(), await settings()
        try:
            spec = validate_spec(str(body.get("shape") or ""), body.get("spec") or {}, tz=st.tz)
            at = next_fire(body["shape"], spec, deps.now(), st.tz)
        except (ValueError, TypeError, KeyError) as e:
            raise HTTPException(400, str(e)) from e
        if at is None:
            raise HTTPException(400, "这个时间已经过了")
        await clock_store.add_clock(deps.pool, s.account, s.companion, kind="user", shape=body["shape"], spec=spec,
                                    note=str(body.get("note") or ""), next_at=at)
        return await patrol_state()

    @app.delete("/api/patrol/clock/{clock_id}")
    async def patrol_delete_clock(clock_id: int):
        await clock_store.delete_clock(deps.pool, sc().account, clock_id, kinds=("user", "self"))
        return await patrol_state()

    @app.post("/api/patrol/forward")
    async def patrol_forward(body: dict = Body(...)):
        """拨快（hours 可以是负数拨回来；reset=true 回到真实时间）。"""
        cur["offset"] = timedelta(0) if body.get("reset") else cur["offset"] + timedelta(hours=float(body.get("hours") or 0))
        return await patrol_state()

    @app.post("/api/patrol/tick")
    async def patrol_tick():
        """跑一圈巡逻（跟正式服务器每分钟那一圈一样：心跳要过门，没到点的不响）。"""
        n = await tick_once(deps, rooms)
        return {**await patrol_state(), "ran": n}

    @app.post("/api/patrol/loop")
    async def patrol_loop_switch(body: dict = Body(...)):
        """测试台自己也每分钟巡一圈（默认关：开着测试台它真的会醒来花钱）。"""
        if body.get("on") and cur["loop"] is None:
            cur["loop"] = asyncio.create_task(patrol_loop(deps, rooms))
        elif not body.get("on") and cur["loop"] is not None:
            cur["loop"].cancel()
            cur["loop"] = None
        return await patrol_state()

    @app.post("/api/patrol/wake")
    async def patrol_wake(body: dict = Body(...)):
        """现在叫醒它（不过门）：reason = whim / night_awake / asleep / user / self，note = 钟上那句。事件跟聊天一样推给页面。"""
        reason = str(body.get("reason") or "whim")
        if reason not in ("whim", "night_awake", "asleep", "user", "self"):
            raise HTTPException(400, "reason 不对")
        if sc().incognito:
            raise HTTPException(400, "无痕里不会醒")
        queue: asyncio.Queue = asyncio.Queue()

        async def emit(ev: dict) -> None:
            await queue.put(ev)

        async def runner() -> None:
            try:
                now = deps.now()
                out = await wake_turn(deps, sc(), reason, str(body.get("note") or ""), now, emit)
                outcome = await record(deps, sc(), reason, out, now)
                await queue.put({"type": "wake", "outcome": outcome, "cost_usd": out.cost_usd, "error": out.error})
            except Exception as e:
                log.exception("wake crashed")
                await queue.put({"type": "error", "kind": "server", "message": f"服务器出错：{e}"})
            finally:
                await queue.put(None)

        task = asyncio.create_task(runner())

        async def stream():
            while (ev := await queue.get()) is not None:
                yield f"data: {json.dumps(ev, ensure_ascii=False, default=str)}\n\n"
            await task

        return StreamingResponse(stream(), media_type="text/event-stream")

    # ── 远事 · 抽屉栏（09-28）：它记着的日子（带排好的三次醒来）、抽屉全文（测试台看得见，正式 app 看不见）──

    async def dates_drawer_state():
        s = sc()
        dates = await far_dates.list_open(deps.pool, s.account, s.companion)
        clocks = await clock_store.list_clocks(deps.pool, s.account, s.companion, kinds=("date",))
        letters = await drawer.mine(deps.pool, s.companion)
        return {
            "dates": [{"id": f.id, "day": f.day.isoformat(), "time": f.at_time, "title": f.title, "note": f.note,
                       "wakes": [{"phase": c.spec.get("phase"), "at": c.next_at.isoformat() if c.next_at else None}
                                 for c in clocks if c.spec.get("date_id") == f.id]} for f in dates],
            "letters": [{"id": x.id, "title": x.title, "content": x.content, "written_at": x.created_at.isoformat(),
                         "unlock_at": x.unlock_at.isoformat() if x.unlock_at else None, "code": x.code,
                         "opened_at": x.opened_at.isoformat() if x.opened_at else None} for x in letters],
        }

    @app.get("/api/dates_drawer")
    async def get_dates_drawer():
        return await dates_drawer_state()

    @app.post("/api/dates")
    async def add_date(body: dict = Body(...)):
        s = sc()
        try:
            await far_dates.add(deps.pool, s.account, s.companion, await settings(),
                                day=date.fromisoformat(str(body.get("day") or "")), at_time=str(body.get("time") or ""),
                                title=str(body.get("title") or ""), note=str(body.get("note") or ""), now=deps.now())
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return await dates_drawer_state()

    @app.delete("/api/dates/{date_id}")
    async def delete_date(date_id: int):
        await far_dates.delete(deps.pool, sc().account, date_id)
        return await dates_drawer_state()

    @app.post("/api/drawer/{letter_id}/open")
    async def open_letter(letter_id: int, body: dict = Body(default={})):
        """假装 TA 在 app 里拆这封（到日子了不用码；没到要输它给的码）。"""
        status, got = await drawer.open_letter(deps.pool, sc().account, letter_id, str(body.get("code") or ""), deps.now())
        return {"status": status, "detail": got if status in ("wrong", "locked") else None,
                **await dates_drawer_state()}

    return app
