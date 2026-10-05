"""醒来一次（巡逻第 5 步）：一个到点的钟 → 该不该醒 → 叫醒它 → 记醒来账 → 排推送 → 定下一次。

- 心跳：先过第一道门（heartbeat.gate），不放行就只把「下次看门」往后挪，不记账（每 20 分钟一行太吵）。
- 你定的 / 它约的：到点就醒，只受每天总上限管；窗口正在聊就推迟一分钟。
- 醒来走等候区的 run_exclusive：同一个窗口同时只跑一轮，TA 开着 app 就一条条推过去。
- 模型报错不推给 TA；心跳连错 3 次在心跳那行的 spec 里记 paused，TA 下次报「在」时清掉（接口那步）。
  没钥匙 / 试用用完不算错，只记账。"""
from __future__ import annotations

import logging
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from brain import accounts, archive
from brain import drawer, far_dates, todos
from food import remark
from music import daily as music_daily
from brain.scope import Scope
from brain.settings import Settings
from brain.turn import Deps, TurnOutcome, run_turn
from brain.wake_text import ASK_AGAIN, MUST_SPEAK, render_wake

from . import diary, morning, store
from .clocks import next_fire, patrol_numbers
from .heartbeat import CHECK_EVERY, Facts, gate
from .store import Clock

log = logging.getLogger(__name__)
BUSY_RETRY = timedelta(minutes=1)
PAUSE_AFTER = 3
NIGHT_SPAN = timedelta(hours=12)      # 「这一晚」往回看多久
PUSH_CHARS = 120


async def window_for(pool, account, companion) -> object:
    """在哪个窗口醒：这个联系人最近用过的普通窗口；一个都没有就开一个。"""
    conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND account_id = $2 "
                               "AND NOT incognito ORDER BY last_at DESC LIMIT 1", companion, account)
    if conv is None:
        conv = await accounts.new_conversation(pool, account, companion)
    return conv


def _day_start(now: datetime, tz: str) -> datetime:
    z = ZoneInfo(tz)
    return datetime.combine(now.astimezone(z).date(), time(0), tzinfo=z)


async def wake_once(deps: Deps, rooms, clock: Clock, now: datetime) -> str:
    """跑一个领到的钟，返回结果（said / silent / error / no_key / skipped_cap / skipped_busy / no / off / gone）。"""
    pool = deps.pool
    if clock.kind == "diary":                                   # 日记（10-01）：不进聊天、不推送、不占每天的份
        return await diary.run(deps, rooms, clock, now)
    acc, comp = clock.account_id, clock.companion_id
    s = Settings.from_dict(await archive.get_settings(pool, comp))
    n = patrol_numbers(s)
    conv = await window_for(pool, acc, comp)
    last_at, _, user_at = await store.last_said(pool, comp)
    woke = await store.wakes_since(pool, comp, _day_start(now, s.tz))

    async def log_it(reason: str, outcome: str, cost: float = 0.0, **detail) -> None:
        await store.log_wake(pool, account=acc, companion=comp, conversation=conv, at=now, reason=reason,
                             clock_id=clock.id if clock.kind != "heartbeat" else None, outcome=outcome, cost_usd=cost,
                             detail=detail)

    async def after_clock() -> None:
        """你定的 / 它约的：定下一次（一次性的响完就删）。"""
        await store.reschedule(pool, clock.id, next_fire(clock.shape, clock.spec, now, s.tz))

    if clock.kind == "heartbeat":
        if not s.heartbeat_on or clock.spec.get("paused"):
            await store.reschedule(pool, clock.id, now + CHECK_EVERY)
            return "off"
        created = await pool.fetchval("SELECT created_at FROM companions WHERE id = $1", comp)
        v = gate(Facts(
            now=now, tz=s.tz, sleep_from=s.sleep_from, sleep_to=s.sleep_to,
            last_said_at=last_at or created,                    # 从没聊过：从联系人建好那一刻算，不会一注册就来找
            last_woke_at=await store.last_woke_at(pool, comp),
            last_active_at=await pool.fetchval("SELECT last_active_at FROM accounts WHERE id = $1", acc),
            wakes_today=woke, night_found=await store.night_found(pool, comp, now - NIGHT_SPAN),
            quiet_streak=await store.quiet_streak(pool, comp, last_user_at=user_at),
            busy=rooms.busy(conv)), n)
        await store.reschedule(pool, clock.id, v.next_check)
        if not v.wake:
            return "no"
        reason = v.reason
    else:
        reason = "user" if clock.kind == "todo" else clock.kind    # user / self / date / meal；待办 = TA 自己定的
        if clock.kind == "todo":                                # 待办（10-01）：打过勾跳过；两个都填的到点人不在那儿就等进出
            t = await todos.get_any(pool, clock.todo_id) if clock.todo_id else None
            if t is None:
                await store.reschedule(pool, clock.id, None)
                return "gone"
            via = clock.spec.get("on") if clock.spec.get("via") == "place" else None
            if todos.is_done(t, now.astimezone(ZoneInfo(s.tz)).date()):
                await after_clock()
                return "done"
            if via is None and t.place_id:
                inside = await pool.fetchval("SELECT inside FROM places WHERE id = $1", t.place_id)
                if not todos.place_ok(t, inside):
                    await pool.execute("UPDATE todos SET waiting_until = $2 WHERE id = $1", t.id, todos.end_of_day(now, s.tz))
                    await after_clock()
                    return "waiting_place"
            clock.note = await todos.wake_note(pool, t, via, s.lang)
        elif clock.kind == "meal":                                # 记一餐说一句（09-30）：每次都说，不占每天的份
            if rooms.busy(conv):
                await store.reschedule(pool, clock.id, now + BUSY_RETRY)
                return "skipped_busy"
            got = await remark.wake_note(pool, acc, now, s.tz, s.lang)
            if got is None:
                await store.reschedule(pool, clock.id, None)
                return "gone"
            clock.note, meal_ids = got
        elif clock.kind == "picks":                             # 每日私选（09-30）：先建池子，再叫醒它挑
            if rooms.busy(conv):
                await store.reschedule(pool, clock.id, now + BUSY_RETRY)
                return "skipped_busy"
            day = now.astimezone(ZoneInfo(s.tz)).date()
            chosen = await music_daily.build(deps, acc, day)
            if not chosen:
                await store.reschedule(pool, clock.id, None)
                await music_daily.ensure_clock(pool, acc, now)
                return "gone"
            clock.note = await music_daily.wake_note(pool, acc, day, chosen, s.lang)
        elif clock.kind == "morning":                             # 起床前醒来准备（10-01）
            if not s.morning_on:                                  # 早上那次单独一个开关（10-01 Tilia）；关了：钟挪到明天
                await morning.ensure_clock(pool, acc, now + timedelta(minutes=1))
                return "off"
            if rooms.busy(conv):
                await store.reschedule(pool, clock.id, now + BUSY_RETRY)
                return "skipped_busy"
            clock.note = ""
            link = await pool.fetchrow("SELECT picks_n, picks_at FROM music_links WHERE account_id = $1", acc)
            if link and link["picks_n"] > 0 and not link["picks_at"]:   # 推歌是默认时间：今天的歌合进这一次
                day = now.astimezone(ZoneInfo(s.tz)).date()
                chosen = await music_daily.build(deps, acc, day)
                if chosen:
                    clock.note = await music_daily.wake_note(pool, acc, day, chosen, s.lang)
                    await music_daily.ensure_clock(pool, acc, now + timedelta(hours=2))   # 推歌的钟挪到明天
        elif clock.kind == "date":                                # 远事：按现在的样子拼那句；删了 / 了结了就作废
            note = await far_dates.wake_note(pool, clock.spec, s.lang)
            if note is None:
                await store.reschedule(pool, clock.id, None)
                return "gone"
            clock.note = note
        if woke >= n.daily_cap and clock.kind not in ("meal", "picks", "morning", "todo"):   # 待办是 TA 要的，一定来
            await log_it(reason, "skipped_cap", note=clock.note)
            await after_clock()
            return "skipped_cap"
        if rooms.busy(conv):
            await store.reschedule(pool, clock.id, now + BUSY_RETRY)
            return "skipped_busy"

    ran, out = await rooms.run_exclusive(conv, lambda emit: wake_turn(
        deps, Scope(acc, comp, conv), reason, clock.note if clock.kind != "heartbeat" else "", now, emit))
    if not ran:                                                 # 刚好被 TA 抢先开口了
        if clock.kind == "heartbeat":
            await log_it(reason, "skipped_busy")
        else:
            await store.reschedule(pool, clock.id, now + BUSY_RETRY)
        return "skipped_busy"
    if clock.kind != "heartbeat":
        await after_clock()
    if clock.kind == "meal":
        await remark.mark_said(pool, meal_ids)
    if clock.kind == "picks":                                   # 挂明天的
        await music_daily.ensure_clock(pool, acc, now + timedelta(minutes=1))
    if clock.kind == "morning":
        await morning.ensure_clock(pool, acc, now + timedelta(minutes=1))
    if out is None:                                             # 窗口在跑的时候被删了
        return "error"
    outcome = await record(deps, Scope(acc, comp, conv), reason, out, now,
                           clock_id=clock.id if clock.kind != "heartbeat" else None,
                           urgent=urgent(clock.kind, clock.spec or {}), quiet=clock.kind == "morning")
    if clock.kind == "heartbeat":
        errors = int(clock.spec.get("errors", 0)) + 1 if outcome == "error" else 0
        spec = {**clock.spec, "errors": errors}
        if errors >= PAUSE_AFTER:
            spec["paused"] = True
            log.warning("heartbeat paused for companion %s after %d errors", comp, errors)
        if spec != clock.spec:
            await store.set_spec(pool, clock.id, spec)
    return outcome


async def wake_turn(deps: Deps, scope: Scope, reason: str, note: str, now: datetime, emit) -> TurnOutcome:
    """拼〔醒来〕、叫醒它跑一轮（测试台的「现在叫醒它」也走这里，跟真巡逻一模一样）。"""
    pool = deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, scope.companion))
    last_at, last_by, _ = await store.last_said(pool, scope.companion)
    envelope = render_wake(s.lang, reason, now, s.tz, last_at=last_at, last_by=last_by,
                           found_today=await store.said_since(pool, scope.companion, _day_start(now, s.tz)), note=note,
                           relationship=s.relationship)
    shelf = await drawer.wake_line(pool, scope.companion, now, s.lang)
    if shelf:
        envelope = f"{envelope}\n{shelf}"
    out = await run_turn(deps, scope, "", emit, wake=envelope, quiet_food=reason == "meal")
    if reason in MUST_SPEAK and not out.said and not out.error:     # TA 要它来的还回 <silent>：明说一次，再叫一次
        first = out.cost_usd
        out = await run_turn(deps, scope, "", emit, wake=f"{envelope}\n{ASK_AGAIN[s.lang if s.lang in ASK_AGAIN else 'en']}",
                             quiet_food=reason == "meal")
        out.cost_usd += first
    if out.said:
        await accounts.touch_conversation(pool, scope.conversation, deps.now())
    return out


def urgent(kind: str, spec: dict) -> bool:
    """分轻重（09-30）：TA 自己定的钟、远事当天那次才算急（时效性通知，穿过勿扰）；它自己约的、心跳、前一晚 / 第二天都不算。"""
    return kind in ("user", "todo") or (kind == "date" and spec.get("phase") == "day")


async def record(deps: Deps, scope: Scope, reason: str, out: TurnOutcome, now: datetime, *,
                 clock_id: int | None = None, urgent: bool = False, quiet: bool = False) -> str:
    """醒来一轮之后：记醒来账，开口了就排一条推送。返回结果（said / silent / error / no_key）。"""
    pool = deps.pool
    outcome = ("no_key" if out.error == "trial_over" else "error" if out.error
               else "said" if out.said else "silent")
    reply = None
    if outcome == "said":
        reply = next((m for m in reversed(await archive.recent(pool, scope.conversation, 3)) if m.role == "assistant"),
                     None)
    await store.log_wake(pool, account=scope.account, companion=scope.companion, conversation=scope.conversation,
                         at=now, reason=reason, clock_id=clock_id, outcome=outcome, cost_usd=out.cost_usd,
                         detail={"error": out.error} if out.error else None, message_id=reply.id if reply else None)
    if outcome == "said":
        if reply is not None:
            await store.queue_push(pool, account=scope.account, companion=scope.companion,
                                   conversation=scope.conversation, text=reply.text.split("\n\n")[0][:PUSH_CHARS],
                                   urgent=urgent, quiet=quiet)
    return outcome
