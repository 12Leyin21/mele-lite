"""Claude 缓存保活（2026-09-29 Tilia要的：忙的人一天就聊几次，但不想缓存扑空）。

账：扑空一次 = 整段前缀按 2 倍重写；保活每 55 分钟一次，只按 0.1 倍读缓存。间隔十几个小时以内都更省。
- 开关默认关（设置 cache_keepalive），只对 Claude（DeepSeek 自己能留几个小时，不用）。
- 每一轮真跑完（聊天、醒来都算）记下这一轮发给模型的请求；TA 再开口就换成新的。
- 巡逻每分钟看一眼：离上次续 / 上次说话满 55 分钟就续一次（1 小时档缓存，读一次续一小时）。
- TA 的睡觉时间到了就放手（不替睡着的人花钱，醒来等 TA 先开口）；一天最多续 DAILY_CAP 次。
- 花的钱照样记在账号的用量上。
- 只记在这台服务器的内存里：重启就没了（没了就等 TA 下次开口再记），以后开多台再挪进数据库。"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from llm.catalog import cost
from patrol.clocks import in_sleep

from . import archive
from .scope import Scope
from .settings import Settings

log = logging.getLogger(__name__)
EVERY = timedelta(minutes=55)
DAILY_CAP = 16


@dataclass
class _Entry:
    scope: Scope
    route: object
    req: object
    last: datetime
    day: str = ""
    count: int = 0


_live: dict[UUID, _Entry] = {}


def reset() -> None:
    _live.clear()


def tracked(conversation: UUID) -> bool:
    return conversation in _live


def forget(conversation: UUID) -> None:
    _live.pop(conversation, None)


def remember(scope: Scope, route, req, now: datetime, *, enabled: bool) -> None:
    """一轮跑完记下它发的请求（只记开了保活的 Claude；无痕不记）。"""
    if not enabled or getattr(route, "provider", "") != "anthropic" or scope.incognito:
        forget(scope.conversation)
        return
    old = _live.get(scope.conversation)
    _live[scope.conversation] = _Entry(scope, route, req, now, old.day if old else "", old.count if old else 0)


async def tick(pool, now: datetime, adapter_for) -> int:
    """巡逻每分钟调一次。返回这一圈续了几个。"""
    sent = 0
    for conv, e in list(_live.items()):
        s = Settings.from_dict(await archive.get_settings(pool, e.scope.companion))
        if not s.cache_keepalive or in_sleep(now, s.tz, s.sleep_from, s.sleep_to):
            forget(conv)
            continue
        if now - e.last < EVERY:
            continue
        today = now.astimezone(ZoneInfo(s.tz)).date().isoformat()
        if e.day != today:
            e.day, e.count = today, 0
        if e.count >= DAILY_CAP:
            continue
        try:
            usage = await adapter_for(e.route).keepalive(e.req)
        except Exception as ex:                          # noqa: BLE001 —— 续不上就放手，等 TA 下次开口
            log.warning("keepalive %s failed: %r", conv, ex)
            forget(conv)
            continue
        e.last, e.count = now, e.count + 1
        model = e.req.model
        await archive.add_usage(pool, e.scope.account, now.astimezone(ZoneInfo(s.tz)).date(), model, usage,
                                cost(usage, model))
        sent += 1
    return sent
