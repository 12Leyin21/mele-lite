"""巡逻的循环（第 5 步）：每分钟领一批到点的钟，一个一个醒。住在接口服务器里（Tilia 09-27 选的做法 A）。
每一圈顺手给没有心跳的联系人补一行（新账号、新联系人、老数据）。一个钟出错只记日志，不让循环停。"""
from __future__ import annotations

import asyncio
import logging

from brain import drawer, far_dates, keepalive, todos

from . import store
from . import diary, morning
from .heartbeat import CHECK_EVERY
from .wake import wake_once

log = logging.getLogger(__name__)
TICK = 60.0


async def tick_once(deps, rooms) -> int:
    now = deps.now()
    await store.ensure_all_heartbeats(deps.pool, now + CHECK_EVERY)
    await morning.ensure_all(deps.pool, now)                    # 起床前醒来准备（10-01）：每个账号一个早上的钟
    await diary.ensure_all(deps.pool, now)                      # 日记（10-01）：每个账号一个凌晨的钟
    await todos.adopt_user_clocks(deps.pool)                    # 「你定的钟」并进待办（10-01）
    try:                                                   # 远事：过了三天没了结的自动了结（09-28）
        await far_dates.auto_resolve(deps.pool, deps.embedder, now)
    except Exception:
        log.exception("patrol: auto-resolve far dates failed")
    try:                                                   # 抽屉：解锁日 TA 起床后推一条（09-28）
        await drawer.queue_unlocks(deps.pool, now)
    except Exception:
        log.exception("patrol: drawer unlock push failed")
    try:                                                   # Claude 缓存保活（09-29，开了的才续）
        from brain.turn import get_adapter
        await keepalive.tick(deps.pool, now, lambda r: get_adapter(deps, r))
    except Exception:
        log.exception("patrol: keepalive failed")
    try:                                                   # 在听什么（09-30）：Mele 关着时隔 5 分钟问一次 Apple Music
        from music import listen
        await listen.poll(deps, now)
    except Exception:
        log.exception("patrol: music poll failed")
    try:                                                   # 朋友圈：到点它来刷（10-01）
        from brain import moment_visit
        await moment_visit.run_due(deps, now)
    except Exception:
        log.exception("patrol: moment visits failed")
    try:                                                   # 相册：TA 加的照片一分钟后它看（10-02）
        from brain import album_look
        await album_look.run_due(deps, now)
    except Exception:
        log.exception("patrol: album looks failed")
    try:                                                   # 塔罗：后台任务没解成的再解一次（10-03）
        from brain import tarot_read
        await tarot_read.run_due(deps, now)
    except Exception:
        log.exception("patrol: tarot reads failed")
    due = await store.claim_due(deps.pool, now)
    for clock in due:
        try:
            await wake_once(deps, rooms, clock, now)
        except Exception:
            log.exception("patrol: clock %s failed", clock.id)
    return len(due)


async def patrol_loop(deps, rooms, *, tick: float = TICK) -> None:
    while True:
        try:
            await tick_once(deps, rooms)
        except Exception:
            log.exception("patrol tick failed")
        await asyncio.sleep(tick)
