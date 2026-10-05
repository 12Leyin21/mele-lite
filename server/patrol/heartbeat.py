"""心跳的第一道门（巡逻第 2 步）：每 20 分钟看一眼，免费——只看几个数，不调模型。

- 白天：距上次（谁说的话，或它上次醒来）超过「白天间隔」→ 心血来潮（whim）
- 深夜 + TA 最近 15 分钟开着 app：还没找够这一晚的次数、距上次至少半小时 → 深夜醒着（night_awake）
- 深夜 + TA 不在：「睡着时间隔」到了 → 睡着（asleep），0 = 不叫
- 护栏：连着 5 次醒来它都不说话、TA 也没回来 → 间隔 ×2，10 次 ×4 封顶（Tilia 09-27：有的模型不爱找人，3 次太快）
正在聊（busy）、今天醒够了（cap）一律不叫。"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from .clocks import PatrolNumbers, in_sleep

CHECK_EVERY = timedelta(minutes=20)
ACTIVE_WITHIN = timedelta(minutes=15)       # 这么久内报过「在」= 还醒着
NIGHT_AWAKE_GAP = timedelta(minutes=30)     # 深夜醒着那种，两次之间至少隔这么久
QUIET_STEP = 5                              # 连着这么多次不说话就翻一倍


@dataclass(frozen=True)
class Facts:
    now: datetime
    tz: str
    sleep_from: str
    sleep_to: str
    last_said_at: datetime | None       # 这个联系人最后一句话（谁说的都算）
    last_woke_at: datetime | None       # 它上次被叫醒（不管说没说）
    last_active_at: datetime | None     # TA 上次报「在」
    wakes_today: int
    night_found: int                    # 这一晚因为「深夜醒着」已经找过 TA 几次（说了话才算）
    quiet_streak: int                   # 最近连着几次醒来没说话（TA 说话或它说话就清零）
    busy: bool                          # 等候区有排着的 / 正在跑一轮


@dataclass(frozen=True)
class Verdict:
    wake: bool
    reason: str | None                  # whim / night_awake / asleep
    next_check: datetime
    blocked: str | None = None          # busy / cap（记醒来账用）


def backoff(quiet_streak: int) -> int:
    return 1 if quiet_streak < QUIET_STEP else 2 if quiet_streak < 2 * QUIET_STEP else 4


def gate(f: Facts, n: PatrolNumbers) -> Verdict:
    nxt = f.now + CHECK_EVERY
    if f.busy:
        return Verdict(False, None, nxt, "busy")
    if f.wakes_today >= n.daily_cap:
        return Verdict(False, None, nxt, "cap")
    marks = [t for t in (f.last_said_at, f.last_woke_at) if t is not None]
    since = f.now - max(marks) if marks else None           # 从没说过话 = 隔了无限久
    mult = backoff(f.quiet_streak)

    def gap_over(minutes: float | timedelta) -> bool:
        need = minutes if isinstance(minutes, timedelta) else timedelta(minutes=minutes)
        return since is None or since >= need * mult

    if in_sleep(f.now, f.tz, f.sleep_from, f.sleep_to):
        awake = f.last_active_at is not None and f.now - f.last_active_at <= ACTIVE_WITHIN
        if awake:
            if f.night_found < n.night_awake_max and gap_over(NIGHT_AWAKE_GAP):
                return Verdict(True, "night_awake", nxt)
            return Verdict(False, None, nxt)
        if n.asleep_gap_min > 0 and gap_over(n.asleep_gap_min):
            return Verdict(True, "asleep", nxt)
        return Verdict(False, None, nxt)
    if gap_over(n.day_gap_min):
        return Verdict(True, "whim", nxt)
    return Verdict(False, None, nxt)
