"""「多久来找你」每档旁边写的「一个月最多大概花多少」（Tilia 09-27：API 是用户出钱，让用户看着价钱选）。

醒一次多少钱：这个联系人最近 30 天醒来的平均花费；还没醒过就按模型单价 × 一次典型的醒来算
（上下文 2 万 token、大半走缓存，回 300 token）。一个月醒几次：白天按间隔醒满、睡着按间隔醒满，
再封顶到每天上限——是「最多」，它常常选不说话、TA 常常在聊，实际会少。深夜醒着那种次数少，不算。"""
from __future__ import annotations

from brain.settings import parse_hm
from llm.catalog import cost
from llm.types import Usage

from .clocks import LEVELS, PatrolNumbers

TYPICAL_WAKE = Usage(input=3000, cache_read=17000, output=300)
DAYS = 30


def sleep_hours(sleep_from: str, sleep_to: str) -> float:
    a, b = parse_hm(sleep_from), parse_hm(sleep_to)
    mins = ((b.hour * 60 + b.minute) - (a.hour * 60 + a.minute)) % 1440
    return mins / 60


def wakes_per_day(n: PatrolNumbers, sleep_from: str, sleep_to: str) -> int:
    night = sleep_hours(sleep_from, sleep_to)
    day = 24 - night
    wakes = day * 60 / n.day_gap_min + (night * 60 / n.asleep_gap_min if n.asleep_gap_min else 0)
    return min(int(wakes), n.daily_cap)


def per_wake_usd(model: str, recent_avg: float | None) -> float | None:
    return recent_avg if recent_avg else cost(TYPICAL_WAKE, model)


def levels_table(model: str, recent_avg: float | None, sleep_from: str, sleep_to: str) -> dict:
    """{档位: {wakes_per_month, usd_per_month}}；模型不在清单里算不出钱就给 None。"""
    each = per_wake_usd(model, recent_avg)
    out = {}
    for name, n in LEVELS.items():
        wakes = wakes_per_day(n, sleep_from, sleep_to) * DAYS
        out[name] = {"wakes_per_month": wakes, "usd_per_month": round(wakes * each, 2) if each is not None else None}
    return out
