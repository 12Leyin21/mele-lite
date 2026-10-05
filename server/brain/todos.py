"""待办（10-01 Tilia，设计 specs/2026-10-01-todo-design.md；点子是她在网上看到的：三个格子）。

一条待办 = 做什么 + 什么时候（可空：一次 / 每天 / 每周几）+ 在哪（可空：常去的地方 + 到了或离开）。
- 有时间的挂一行钟（clocks.kind='todo'，todo_id 指回来；删待办连钟一起删）。
- 地点进出时（手机的地理围栏报上来）插一行一次性的 todo 钟，巡逻一分钟内领走、叫醒它提醒——醒来、推送、记账都走现成的路。
- 两个都填：到点时人在那儿（到了 = 在里面；离开 = 不在里面）才提醒；不在就等到当天结束，进出对了再提醒。
- 打勾 = 这一期做完：一次性 / 只有地点 / 没时间的 = 做完；每天的 = 今天；每周的 = 这周（周一起）。下一期自动没勾。
- 「你定的钟」并进待办（Tilia 10-01）：老的 user 钟由巡逻顺手收编（adopt_user_clocks）。"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from patrol import clocks as C

WHAT_MAX = 200
PLACES_MAX = 20
RADIUS = (100, 1000)
PLACE_DEBOUNCE = timedelta(minutes=30)     # 围栏边上来回抖：30 分钟内同一条不重复提醒
SHAPES = ("once", "at")                    # 新写的只有这两种；收编的老钟可能是 every / window


@dataclass
class Place:
    id: int
    account_id: UUID
    name: str
    lat: float
    lon: float
    radius: int
    inside: bool | None
    state_at: datetime | None
    created_at: datetime

    def to_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "lat": self.lat, "lon": self.lon, "radius": self.radius,
                "inside": self.inside}


@dataclass
class Todo:
    id: int
    account_id: UUID
    companion_id: UUID
    what: str
    shape: str | None
    spec: dict
    place_id: int | None
    place_on: str | None
    done_on: date | None
    waiting_until: datetime | None
    reminded_at: datetime | None
    created_by: str
    created_at: datetime
    updated_at: datetime


_PCOLS = "id, account_id, name, lat, lon, radius, inside, state_at, created_at"
_TCOLS = ("id, account_id, companion_id, what, shape, spec, place_id, place_on, done_on, waiting_until, reminded_at, "
          "created_by, created_at, updated_at")


def _todo(r) -> Todo:
    d = dict(r)
    d["spec"] = json.loads(d["spec"]) if isinstance(d["spec"], str) else dict(d["spec"] or {})
    return Todo(**d)


def _place(r) -> Place:
    return Place(**dict(r))


# ── 一期一期：打勾管到哪天 ──

def period(t: Todo) -> str:
    """once = 做完就完；day = 每天一期；week = 每周一期。没时间的、只有地点的、收编来的 every / window 都算 once / day。"""
    if t.shape == "at":
        return "week" if t.spec.get("days") else "day"
    if t.shape in ("every", "window"):
        return "day"
    return "once"


def is_done(t: Todo, today: date) -> bool:
    if t.done_on is None:
        return False
    p = period(t)
    if p == "once":
        return True
    if p == "day":
        return t.done_on == today
    return t.done_on >= today - timedelta(days=today.weekday())


_WD = {"zh": "一二三四五六日", "en": ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")}


def describe_when(shape: str | None, spec: dict, tz: str, lang: str = "zh") -> str:
    zh = lang == "zh"
    if not shape:
        return ""
    if shape == "once":
        at = datetime.fromisoformat(spec["at"]).astimezone(ZoneInfo(tz))
        return f"{at.month}/{at.day} {at:%H:%M}"
    if shape == "at":
        days = spec.get("days") or []
        if not days:
            return f"每天 {spec['time']}" if zh else f"Daily {spec['time']}"
        sep = "、" if zh else ", "
        names = sep.join(_WD["zh" if zh else "en"][d] for d in days)
        return f"每周{names} {spec['time']}" if zh else f"{names} {spec['time']}"
    if shape == "every":
        return f"每隔 {spec['every_min']} 分钟" if zh else f"Every {spec['every_min']} min"
    return f"每天 {spec['from']}～{spec['to']} 之间" if zh else f"Daily between {spec['from']} and {spec['to']}"


# ── 常去的地方 ──

def _check_place(name: str, lat, lon, radius) -> tuple[str, float, float, int]:
    name = (name or "").strip()[:20]
    if not name:
        raise ValueError("地方要有个名字")
    lat, lon, radius = float(lat), float(lon), int(radius or 150)
    if not (-90 <= lat <= 90 and -180 <= lon <= 180) or math.isnan(lat) or math.isnan(lon):
        raise ValueError("经纬度不对")
    return name, lat, lon, max(RADIUS[0], min(RADIUS[1], radius))


async def add_place(pool, account: UUID, *, name: str, lat, lon, radius=150) -> Place:
    name, lat, lon, radius = _check_place(name, lat, lon, radius)
    if await pool.fetchval("SELECT count(*) FROM places WHERE account_id = $1", account) >= PLACES_MAX:
        raise ValueError(f"最多存 {PLACES_MAX} 个地方，先删几个")
    r = await pool.fetchrow(f"INSERT INTO places (account_id, name, lat, lon, radius) VALUES ($1, $2, $3, $4, $5) "
                            f"RETURNING {_PCOLS}", account, name, lat, lon, radius)
    return _place(r)


async def update_place(pool, account: UUID, place_id: int, *, name=None, lat=None, lon=None, radius=None) -> Place:
    old = await get_place(pool, account, place_id)
    if old is None:
        raise LookupError("没有这个地方")
    name, lat, lon, radius = _check_place(name if name is not None else old.name, lat if lat is not None else old.lat,
                                          lon if lon is not None else old.lon, radius if radius is not None else old.radius)
    moved = (lat, lon, radius) != (old.lat, old.lon, old.radius)
    r = await pool.fetchrow(
        f"""UPDATE places SET name = $3, lat = $4, lon = $5, radius = $6,
                   inside = CASE WHEN $7 THEN NULL ELSE inside END, state_at = CASE WHEN $7 THEN NULL ELSE state_at END
            WHERE id = $1 AND account_id = $2 RETURNING {_PCOLS}""", place_id, account, name, lat, lon, radius, moved)
    return _place(r)


async def delete_place(pool, account: UUID, place_id: int) -> bool:
    done = await pool.execute("DELETE FROM places WHERE id = $1 AND account_id = $2", place_id, account)
    return done.endswith(" 1")


async def get_place(pool, account: UUID, place_id: int) -> Place | None:
    r = await pool.fetchrow(f"SELECT {_PCOLS} FROM places WHERE id = $1 AND account_id = $2", place_id, account)
    return _place(r) if r else None


async def list_places(pool, account: UUID) -> list[Place]:
    return [_place(r) for r in await pool.fetch(f"SELECT {_PCOLS} FROM places WHERE account_id = $1 ORDER BY id", account)]


async def place_by_name(pool, account: UUID, name: str) -> Place | None:
    r = await pool.fetchrow(f"SELECT {_PCOLS} FROM places WHERE account_id = $1 AND lower(name) = lower($2)",
                            account, (name or "").strip())
    return _place(r) if r else None


# ── 待办 ──

async def _tz(pool, companion: UUID) -> str:
    from brain import archive
    from brain.settings import Settings
    return Settings.from_dict(await archive.get_settings(pool, companion)).tz


def _when(shape: str | None, spec: dict | None, tz: str) -> tuple[str | None, dict]:
    if not shape:
        return None, {}
    if shape not in SHAPES:
        raise ValueError("时间只能是某一天某个时间（once）或每天 / 每周几的某个时间（at）")
    return shape, C.validate_spec(shape, spec or {}, tz=tz)


async def _arm(pool, t: Todo, tz: str, now: datetime) -> None:
    """按待办现在的时间重挂它的钟（只动按时间的那行；地点触发的一次性钟不动）。"""
    await pool.execute("DELETE FROM clocks WHERE todo_id = $1 AND NOT (spec ? 'via')", t.id)
    if not t.shape:
        return
    at = C.next_fire(t.shape, t.spec, now, tz)
    if at is None:
        return
    await pool.execute("""INSERT INTO clocks (account_id, companion_id, kind, shape, spec, note, next_at, todo_id)
                          VALUES ($1, $2, 'todo', $3, $4::jsonb, $5, $6, $7)""",
                       t.account_id, t.companion_id, t.shape, json.dumps(t.spec), t.what, at, t.id)


async def _check_link(pool, account: UUID, companion: UUID, place_id, place_on) -> tuple[int | None, str | None]:
    if not await pool.fetchval("SELECT EXISTS (SELECT 1 FROM companions WHERE id = $1 AND account_id = $2)",
                               companion, account):
        raise PermissionError("没有这个联系人")
    if place_id is None:
        return None, None
    if await get_place(pool, account, int(place_id)) is None:
        raise ValueError("没有这个地方")
    if place_on not in ("arrive", "leave"):
        raise ValueError("在哪要选「到了提醒」还是「离开时提醒」")
    return int(place_id), place_on


async def create(pool, account: UUID, companion: UUID, *, what: str, shape: str | None = None, spec: dict | None = None,
                 place_id: int | None = None, place_on: str | None = None, now: datetime,
                 created_by: str = "user") -> Todo:
    what = (what or "").strip()[:WHAT_MAX]
    if not what:
        raise ValueError("要做什么还没写")
    place_id, place_on = await _check_link(pool, account, companion, place_id, place_on)
    tz = await _tz(pool, companion)
    shape, spec = _when(shape, spec, tz)
    if shape == "once" and C.next_fire(shape, spec, now, tz) is None:
        raise ValueError("这个时间已经过了")
    r = await pool.fetchrow(
        f"""INSERT INTO todos (account_id, companion_id, what, shape, spec, place_id, place_on, created_by, created_at,
                               updated_at)
            VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $9, $9) RETURNING {_TCOLS}""",
        account, companion, what, shape, json.dumps(spec), place_id, place_on, created_by, now)
    t = _todo(r)
    await _arm(pool, t, tz, now)
    return t


_UNSET = object()


async def update(pool, account: UUID, todo_id: int, *, now: datetime, what=_UNSET, shape=_UNSET, spec=_UNSET,
                 place_id=_UNSET, place_on=_UNSET, companion=_UNSET) -> Todo:
    old = await get(pool, account, todo_id)
    if old is None:
        raise LookupError("没有这条待办")
    what = old.what if what is _UNSET else (what or "").strip()[:WHAT_MAX]
    if not what:
        raise ValueError("要做什么还没写")
    comp = old.companion_id if companion is _UNSET else companion
    pid = old.place_id if place_id is _UNSET else place_id
    pon = old.place_on if place_on is _UNSET else place_on
    pid, pon = await _check_link(pool, account, comp, pid, pon)
    tz = await _tz(pool, comp)
    if shape is _UNSET and spec is _UNSET:
        shape2, spec2 = old.shape, old.spec
    else:
        shape2, spec2 = _when(old.shape if shape is _UNSET else shape, old.spec if spec is _UNSET else spec, tz)
    r = await pool.fetchrow(
        f"""UPDATE todos SET what = $3, shape = $4, spec = $5::jsonb, place_id = $6, place_on = $7, companion_id = $8,
                   waiting_until = NULL, updated_at = $9
            WHERE id = $1 AND account_id = $2 RETURNING {_TCOLS}""",
        todo_id, account, what, shape2, json.dumps(spec2), pid, pon, comp, now)
    t = _todo(r)
    await _arm(pool, t, tz, now)
    return t


async def delete(pool, account: UUID, todo_id: int) -> bool:
    done = await pool.execute("DELETE FROM todos WHERE id = $1 AND account_id = $2", todo_id, account)
    return done.endswith(" 1")


async def get(pool, account: UUID, todo_id: int) -> Todo | None:
    r = await pool.fetchrow(f"SELECT {_TCOLS} FROM todos WHERE id = $1 AND account_id = $2", todo_id, account)
    return _todo(r) if r else None


async def get_any(pool, todo_id: int) -> Todo | None:
    r = await pool.fetchrow(f"SELECT {_TCOLS} FROM todos WHERE id = $1", todo_id)
    return _todo(r) if r else None


async def list_all(pool, account: UUID) -> list[Todo]:
    return [_todo(r) for r in await pool.fetch(f"SELECT {_TCOLS} FROM todos WHERE account_id = $1 ORDER BY created_at, id",
                                               account)]


async def set_done(pool, account: UUID, todo_id: int, done: bool, now: datetime) -> Todo:
    """打勾 / 取消。一次性的打勾连钟一起收；取消打勾就按时间重挂。"""
    t = await get(pool, account, todo_id)
    if t is None:
        raise LookupError("没有这条待办")
    tz = await _tz(pool, t.companion_id)
    today = now.astimezone(ZoneInfo(tz)).date()
    r = await pool.fetchrow(f"UPDATE todos SET done_on = $3, waiting_until = NULL, updated_at = $4 "
                            f"WHERE id = $1 AND account_id = $2 RETURNING {_TCOLS}",
                            todo_id, account, today if done else None, now)
    t = _todo(r)
    if done and period(t) == "once":
        await pool.execute("DELETE FROM clocks WHERE todo_id = $1", t.id)
    elif not done:
        await _arm(pool, t, tz, now)
    return t


def to_dict(t: Todo, today: date, tz: str, places: dict[int, Place], names: dict[UUID, str], lang: str = "zh") -> dict:
    p = places.get(t.place_id) if t.place_id else None
    return {"id": t.id, "what": t.what, "companion_id": str(t.companion_id), "companion": names.get(t.companion_id, ""),
            "shape": t.shape, "spec": t.spec, "when": describe_when(t.shape, t.spec, tz, lang),
            "place_id": t.place_id, "place": p.name if p else None, "place_on": t.place_on,
            "repeat": period(t), "done": is_done(t, today), "created_by": t.created_by}


# ── 老钟收编 ──

async def adopt_user_clocks(pool) -> int:
    """「你定的钟」并进待办：每个 user 钟变成一条待办（做什么 = 钟的备注），钟改成 kind='todo' 挂上 todo_id。"""
    rows = await pool.fetch("SELECT id, account_id, companion_id, shape, spec, note, created_at FROM clocks WHERE kind = 'user'")
    for r in rows:
        tid = await pool.fetchval(
            """INSERT INTO todos (account_id, companion_id, what, shape, spec, created_at, updated_at)
               VALUES ($1, $2, $3, $4, $5::jsonb, $6, $6) RETURNING id""",
            r["account_id"], r["companion_id"], (r["note"] or "").strip() or "提醒", r["shape"],
            r["spec"] if isinstance(r["spec"], str) else json.dumps(r["spec"]), r["created_at"])
        await pool.execute("UPDATE clocks SET kind = 'todo', todo_id = $2 WHERE id = $1", r["id"], tid)
    return len(rows)


# ── 提醒：到点 / 进出 ──

def place_ok(t: Todo, inside: bool | None) -> bool:
    """到点时人在不在「对的那一边」：到了 = 在里面；离开 = 不在里面。不知道的当不在（等进出事件）。"""
    if inside is None:
        return False
    return inside if t.place_on == "arrive" else not inside


def end_of_day(now: datetime, tz: str) -> datetime:
    z = ZoneInfo(tz)
    return datetime.combine(now.astimezone(z).date() + timedelta(days=1), time(0), tzinfo=z)


async def place_event(pool, account: UUID, place_id: int, inside: bool, now: datetime, *, sync: bool = False) -> list[int]:
    """手机报：进了 / 出了某个地方。记下状态；对得上的待办插一行一次性的提醒钟。返回要提醒的待办编号。
    sync = 只是对一下「现在在不在里面」（刚开始盯时问的、iOS 跟着进出顺手报的），不算进出，不提醒。
    不拿「状态没变」挡：iOS 的状态报告可能比真正的进出事件先到；重复的进出靠 30 分钟防抖。"""
    p = await get_place(pool, account, place_id)
    if p is None:
        raise LookupError("没有这个地方")
    await pool.execute("UPDATE places SET inside = $2, state_at = $3 WHERE id = $1", place_id, inside, now)
    if sync:
        return []
    want = "arrive" if inside else "leave"
    rows = await pool.fetch(f"SELECT {_TCOLS} FROM todos WHERE account_id = $1 AND place_id = $2 AND place_on = $3",
                            account, place_id, want)
    fired = []
    for t in map(_todo, rows):
        tz = await _tz(pool, t.companion_id)
        if is_done(t, now.astimezone(ZoneInfo(tz)).date()):
            continue
        if t.shape and not (t.waiting_until and t.waiting_until > now):     # 有时间的：只在「到点了在等」的时候
            continue
        if t.reminded_at and now - t.reminded_at < PLACE_DEBOUNCE:
            continue
        await pool.execute("UPDATE todos SET reminded_at = $2, waiting_until = NULL WHERE id = $1", t.id, now)
        await pool.execute("""INSERT INTO clocks (account_id, companion_id, kind, shape, spec, note, next_at, todo_id)
                              VALUES ($1, $2, 'todo', 'once', $3::jsonb, $4, $5, $6)""",
                           t.account_id, t.companion_id,
                           json.dumps({"at": now.isoformat(), "via": "place", "on": want}), t.what, now, t.id)
        fired.append(t.id)
    return fired


_NOTE = {"zh": {"head": "TA 的待办：{what}", "time": "（定的时间到了）", "arrive": "（TA 刚到了{place}）",
                "leave": "（TA 刚离开{place}）"},
         "en": {"head": "Their to-do: {what}", "time": " (the time they set has come)", "arrive": " (they just got to {place})",
                "leave": " (they just left {place})"}}


async def wake_note(pool, t: Todo, via: str | None, lang: str) -> str:
    L = _NOTE[lang if lang in _NOTE else "en"]
    note = L["head"].format(what=t.what)
    if via in ("arrive", "leave") and t.place_id:
        p = await pool.fetchrow("SELECT name FROM places WHERE id = $1", t.place_id)
        return note + L[via].format(place=p["name"] if p else "")
    return note + L["time"]
