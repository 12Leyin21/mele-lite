"""钟的纯计算（巡逻第 1 步）：下一次什么时候响、深夜不深夜、「多久来找你」四档的数字。不碰数据库。

钟的四种样子（spec 存成 JSON）：
- at      固定时间：{"time": "08:00", "days": [0..6]}（周一 = 0；空 = 每天）
- once    一次性：  {"at": "<UTC 的 ISO 时间>"}（收的时候可以是「YYYY-MM-DD HH:MM」本地时间）
- every   每隔几分钟：{"every_min": 120, "from": "09:00", "to": "21:00"}（from == to = 全天；可跨午夜）
- window  时间段里随机一刻，每天一次：{"from": "19:00", "to": "22:00"}（可跨午夜）

时间都按联系人设置里的时区算，墙上的钟说了算：夏令时那天八点照旧是八点。返回的时间一律是 UTC。
比较前都先换成 UTC——同一个 ZoneInfo 的两个时间 Python 会按墙上时间比，碰上夏令时会比错。"""
from __future__ import annotations

import random
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from brain.settings import Settings, parse_hm

SHAPES = ("at", "once", "every", "window")
MIN_EVERY = 15
DAY = 1440


@dataclass(frozen=True)
class PatrolNumbers:
    day_gap_min: int          # 白天：距上次说话多久叫醒它一次
    night_awake_max: int      # 深夜 TA 醒着：一晚最多找几次（说了话才算）
    asleep_gap_min: int       # TA 睡着：多久叫醒它一次；0 = 不叫
    daily_cap: int            # 一天最多醒几次（三类钟都算）


LEVELS = {                    # Tilia 09-27 定
    "low": PatrolNumbers(240, 1, 0, 6),
    "mid": PatrolNumbers(120, 3, 180, 12),
    "high": PatrolNumbers(60, 5, 90, 24),
    "max": PatrolNumbers(30, 7, 45, 48),
}


def patrol_numbers(s: Settings) -> PatrolNumbers:
    """档位的数字，再盖上高级设置里单独改过的。"""
    return replace(LEVELS[s.patrol_level], **(s.patrol_overrides or {}))


def _mins(hm: str) -> int:
    t = parse_hm(hm)
    return t.hour * 60 + t.minute


def _hm(m: int) -> str:
    return f"{m // 60:02d}:{m % 60:02d}"


def _utc(dt: datetime) -> datetime:
    return dt.astimezone(timezone.utc)


def _wall(day: date, minute: int, tz: str) -> datetime:
    """那天本地 0 点起第 minute 分钟（可以超过一天）的墙上时间，换成 UTC。"""
    return _utc(datetime.combine(day, time(0), tzinfo=ZoneInfo(tz)) + timedelta(minutes=minute))


def _span(spec: dict) -> tuple[int, int]:
    start = _mins(spec["from"])
    dur = (_mins(spec["to"]) - start) % DAY
    return start, dur or DAY


def validate_spec(shape: str, spec: dict, *, tz: str | None = None) -> dict:
    """检查并整理成存库的样子；不对就 ValueError（信息是给接口回 400 用的）。"""
    spec = dict(spec or {})
    if shape == "at":
        days = sorted({int(d) for d in spec.get("days") or []})
        if any(not 0 <= d <= 6 for d in days):
            raise ValueError("days must be 0..6 (Monday = 0)")
        return {"time": _hm(_mins(spec.get("time", ""))), "days": days}
    if shape == "once":
        raw = str(spec.get("at") or "").strip()
        try:
            at = datetime.fromisoformat(raw)
        except ValueError as e:
            raise ValueError("at must look like 2026-10-03 14:00") from e
        if at.tzinfo is None:
            if not tz:
                raise ValueError("a local time needs a time zone")
            at = at.replace(tzinfo=ZoneInfo(tz))
        return {"at": _utc(at).isoformat()}
    if shape == "every":
        every = int(spec.get("every_min") or 0)
        if not MIN_EVERY <= every <= DAY:
            raise ValueError(f"every_min must be {MIN_EVERY}..{DAY}")
        return {"every_min": every, "from": _hm(_mins(spec.get("from", "00:00"))),
                "to": _hm(_mins(spec.get("to", "00:00")))}
    if shape == "window":
        frm, to = _mins(spec.get("from", "")), _mins(spec.get("to", ""))
        if frm == to:
            raise ValueError("window from and to must differ")
        return {"from": _hm(frm), "to": _hm(to)}
    raise ValueError(f"shape must be one of {SHAPES}")


def next_fire(shape: str, spec: dict, after: datetime, tz: str, rng: random.Random | None = None) -> datetime | None:
    """严格晚于 after 的下一次（UTC）；一次性的过了就 None。"""
    after = _utc(after)
    today = after.astimezone(ZoneInfo(tz)).date()
    if shape == "at":
        m, days = _mins(spec["time"]), spec.get("days") or []
        for d in range(8):
            day = today + timedelta(days=d)
            if days and day.weekday() not in days:
                continue
            if (t := _wall(day, m, tz)) > after:
                return t
        return None
    if shape == "once":
        t = datetime.fromisoformat(spec["at"])
        return t if t > after else None
    if shape == "every":
        start, dur = _span(spec)
        every = spec["every_min"]
        found = [t for d in (-1, 0, 1)
                 for k in range(dur // every + 1)
                 if (t := _wall(today + timedelta(days=d), start + k * every, tz)) > after]
        return min(found) if found else None
    if shape == "window":
        start, dur = _span(spec)
        for d in range(3):                           # 今天的段还没开始就今天，不然明天——一天只响一次
            day = today + timedelta(days=d)
            if _wall(day, start, tz) > after:
                return _wall(day, start + (rng or random).randrange(dur), tz)
        return None
    raise ValueError(f"unknown shape {shape!r}")


def in_sleep(now: datetime, tz: str, sleep_from: str, sleep_to: str) -> bool:
    """现在是不是 TA 的睡觉段（可跨午夜；from == to 当作没设睡觉段）。"""
    t = now.astimezone(ZoneInfo(tz)).time()
    a, b = parse_hm(sleep_from), parse_hm(sleep_to)
    if a == b:
        return False
    return a <= t < b if a < b else (t >= a or t < b)
