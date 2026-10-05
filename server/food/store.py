"""饮食的存取（09-29）。一切按账号：每个查询都带 account_id。照片是附件（attachments），一餐不限张数。"""
from __future__ import annotations

import json
from datetime import date, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from brain import accounts, archive

from . import logic as L

_COLS = ("id, day, meal, text, detail, portion, kcal, protein, carbs, fat, status, note, source, ext_id, "
         "created_at, updated_at")


class FoodError(ValueError):
    pass


async def account_tz(pool, account: UUID) -> str:
    """饮食按哪天算：账号第一个联系人的时区（各联系人的时区会跟着手机同步，都一样）。"""
    comps = await accounts.list_companions(pool, account)
    return (await archive.get_settings(pool, comps[0])).get("tz") or "UTC" if comps else "UTC"


async def today(pool, account: UUID, now: datetime) -> date:
    return now.astimezone(ZoneInfo(await account_tz(pool, account))).date()


def _entry(r, photos: list[str]) -> dict:
    d = dict(r)
    d["date"] = d.pop("day").isoformat()
    for k in ("created_at", "updated_at"):
        d[k] = d[k].isoformat()
    for k in ("kcal", "protein", "carbs", "fat"):
        if d[k] is not None:
            d[k] = round(float(d[k]), 1) if k != "kcal" else round(float(d[k]))
    d["photos"] = [{"id": p, "url": f"/attachments/{p}"} for p in photos]
    return d


async def _photos_of(pool, ids: list[int]) -> dict[int, list[str]]:
    rows = await pool.fetch("SELECT entry_id, attachment_id FROM food_photos WHERE entry_id = ANY($1::bigint[]) "
                            "ORDER BY entry_id, pos", ids) if ids else []
    out: dict[int, list[str]] = {}
    for r in rows:
        out.setdefault(r["entry_id"], []).append(str(r["attachment_id"]))
    return out


async def _check_photos(pool, account: UUID, photos: list) -> list[UUID]:
    try:
        ids = [UUID(str(p)) for p in photos or []][:30]
    except ValueError:
        raise FoodError("照片编号不对") from None
    if ids:
        mine = await pool.fetchval("SELECT count(*) FROM attachments WHERE account_id = $1 AND id = ANY($2::uuid[]) "
                                   "AND kind = 'image'", account, ids)
        if mine != len(set(ids)):
            raise FoodError("照片编号不对")
    return list(dict.fromkeys(ids))


async def _set_photos(con, entry_id: int, ids: list[UUID]) -> None:
    await con.execute("DELETE FROM food_photos WHERE entry_id = $1", entry_id)
    for i, pid in enumerate(ids):
        await con.execute("INSERT INTO food_photos (entry_id, attachment_id, pos) VALUES ($1, $2, $3)", entry_id, pid, i)


async def get(pool, account: UUID, entry_id: int) -> dict | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM food_entries WHERE id = $1 AND account_id = $2", entry_id, account)
    return _entry(r, (await _photos_of(pool, [entry_id])).get(entry_id, [])) if r else None


async def add(pool, account: UUID, payload: dict, *, day: date, source: str = "app", now: datetime | None = None) -> dict:
    """记一条。没 kcal = 待估（status pending，told=false 等估好再告诉它）；有 kcal = 手填（told=false，下一轮告诉它）。"""
    e, err = L.clean_entry(payload)
    if e is None:
        raise FoodError(err)
    photos = await _check_photos(pool, account, payload.get("photos"))
    ext = str(payload.get("ext_id") or "").strip()[:80] or None
    if ext and await pool.fetchval("SELECT 1 FROM food_deleted_ext WHERE account_id = $1 AND ext_id = $2", account, ext):
        raise FoodError("这条删过了，不再导回")
    status = "pending" if e["kcal"] is None else "manual"
    async with pool.acquire() as con, con.transaction():
        r = await con.fetchrow(
            f"""INSERT INTO food_entries (account_id, day, meal, text, detail, portion, kcal, protein, carbs, fat,
                                          status, source, ext_id, told, created_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, FALSE, COALESCE($14, now()))
                ON CONFLICT (account_id, ext_id) WHERE ext_id IS NOT NULL DO NOTHING RETURNING {_COLS}""",
            account, day, e["meal"], e["text"], e["detail"], e["portion"], e["kcal"], e["protein"], e["carbs"], e["fat"],
            status, source if source in ("app", "lumi", "watch") else "app", ext, now)
        if r is None:
            raise FoodError("这条已经记过了")
        await _set_photos(con, r["id"], photos)
    return _entry(r, [str(p) for p in photos])


async def update(pool, account: UUID, entry_id: int, payload: dict) -> dict | None:
    cur = await get(pool, account, entry_id)
    if cur is None:
        return None
    merged = {**cur, **{k: v for k, v in payload.items() if k != "photos"}}
    e, err = L.clean_entry(merged)
    if e is None:
        raise FoodError(err)
    numbers = any(k in payload for k in ("kcal", "protein", "carbs", "fat"))
    status = ("manual" if e["kcal"] is not None else "pending") if numbers else cur["status"]
    if not numbers and (payload.get("text") not in (None, cur["text"]) or payload.get("detail") not in (None, cur["detail"])
                        or "photos" in payload) and cur["status"] != "manual":
        status, e["kcal"] = "pending", None                  # 改了吃的是什么、没给数：重新估
    async with pool.acquire() as con, con.transaction():
        await con.execute(
            """UPDATE food_entries SET meal = $3, text = $4, detail = $5, portion = $6, kcal = $7, protein = $8,
               carbs = $9, fat = $10, status = $11, updated_at = now(), told = CASE WHEN $11 <> status THEN FALSE ELSE told END,
               est_kcal = CASE WHEN $11 = 'manual' AND status = 'estimated' THEN kcal WHEN $11 = 'pending' THEN NULL
                               ELSE est_kcal END,                      -- 估好的被 TA 手改：记下原来估的（09-30）
               est_portion = CASE WHEN $11 = 'manual' AND status = 'estimated' THEN portion ELSE est_portion END
               WHERE id = $1 AND account_id = $2""",
            entry_id, account, e["meal"], e["text"], e["detail"], e["portion"], e["kcal"],
            e["protein"] if e["kcal"] is not None else None, e["carbs"] if e["kcal"] is not None else None,
            e["fat"] if e["kcal"] is not None else None, status)
        if "photos" in payload:
            await _set_photos(con, entry_id, await _check_photos(pool, account, payload["photos"]))
    return await get(pool, account, entry_id)


async def delete(pool, account: UUID, entry_id: int) -> bool:
    ext = await pool.fetchrow("DELETE FROM food_entries WHERE id = $1 AND account_id = $2 RETURNING ext_id", entry_id, account)
    if ext is None:
        return False
    if ext["ext_id"]:
        await pool.execute("INSERT INTO food_deleted_ext VALUES ($1, $2) ON CONFLICT DO NOTHING", account, ext["ext_id"])
    return True


async def settings(pool, account: UUID) -> dict:
    raw = await pool.fetchval("SELECT data FROM food_settings WHERE account_id = $1", account)
    return {**L.DEFAULT_SETTINGS, **(json.loads(raw) if isinstance(raw, str) else (raw or {}))}


async def save_settings(pool, account: UUID, body: dict) -> dict:
    keep = {k: body[k] for k in ("goal", "height_cm", "weight_kg", "age", "sex", "activity", "kcal", "protein", "country", "remark")
            if k in body}
    if "goal" in keep and keep["goal"] not in L.GOALS:
        raise FoodError(f"goal 只能是 {'/'.join(L.GOALS)}")
    s = {**await settings(pool, account), **keep}
    L.targets(s)                                             # 数字坏的在这儿就报错
    await pool.execute("INSERT INTO food_settings (account_id, data) VALUES ($1, $2::jsonb) ON CONFLICT (account_id) "
                       "DO UPDATE SET data = $2::jsonb", account, json.dumps(s))
    return s


async def entries_on(pool, account: UUID, day: date) -> list[dict]:
    rows = await pool.fetch(f"SELECT {_COLS} FROM food_entries WHERE account_id = $1 AND day = $2 ORDER BY created_at, id",
                            account, day)
    ph = await _photos_of(pool, [r["id"] for r in rows])
    return [_entry(r, ph.get(r["id"], [])) for r in rows]


async def cover(pool, account: UUID, day: date, entries: list[dict]) -> str:
    c = await pool.fetchval("SELECT attachment_id FROM food_covers WHERE account_id = $1 AND day = $2", account, day)
    if c:
        return f"attachments/{c}"   # 给 app 的取图路径（不带开头的 /）
    first = next((p for e in entries for p in e["photos"]), None)
    return first["url"].lstrip("/") if first else ""


async def day_view(pool, account: UUID, day: date) -> dict:
    entries = await entries_on(pool, account, day)
    tgt = L.targets(await settings(pool, account))
    return {"date": day.isoformat(), "entries": entries, "targets": tgt, "summary": L.summary(entries, tgt),
            "cover": await cover(pool, account, day, entries)}


async def days(pool, account: UUID, *, limit: int = 60, q: str = "") -> list[dict]:
    like = f"%{q.strip()}%" if q.strip() else None
    ds = await pool.fetch("SELECT DISTINCT day FROM food_entries WHERE account_id = $1 AND ($2::text IS NULL OR text ILIKE $2) "
                          "ORDER BY day DESC LIMIT $3", account, like, max(1, min(limit, 400)))
    out = []
    for d in ds:
        entries = await entries_on(pool, account, d["day"])
        s = L.summary(entries, None)
        out.append({"date": d["day"].isoformat(), "kcal": s["kcal"], "net": s["net"], "pending": s["pending"],
                    "blurb": L.day_blurb(entries), "photo": await cover(pool, account, d["day"], entries)})
    return out


async def set_cover(pool, account: UUID, day: date, attachment: str) -> None:
    if not attachment:
        await pool.execute("DELETE FROM food_covers WHERE account_id = $1 AND day = $2", account, day)
        return
    [aid] = await _check_photos(pool, account, [attachment])
    await pool.execute("INSERT INTO food_covers VALUES ($1, $2, $3) ON CONFLICT (account_id, day) DO UPDATE SET attachment_id = $3",
                       account, day, aid)


async def export(pool, account: UUID) -> dict:
    rows = await pool.fetch(f"SELECT {_COLS} FROM food_entries WHERE account_id = $1 ORDER BY day, id", account)
    ph = await _photos_of(pool, [r["id"] for r in rows])
    return {"settings": await settings(pool, account), "entries": [_entry(r, ph.get(r["id"], [])) for r in rows]}


FOOD_NOTE = {"zh": ("〔饮食〕TA 刚记了：{items}。今天一共 {total} 千卡。", "{meal} {text}（约 {kcal} 千卡）",
                    "{meal} {text}（没估出来）"),
             "en": ("〔Food〕They just logged: {items}. {total} kcal so far today.", "{meal} {text} (~{kcal} kcal)",
                    "{meal} {text} (couldn't estimate)")}


async def pending_note(pool, account: UUID, now: datetime, lang: str) -> str:
    """〔饮食〕：TA 刚记的、刚估好的，下一轮告诉它一次（标 told）；还在估的等估完再说；平时空。"""
    rows = await pool.fetch(
        """UPDATE food_entries SET told = TRUE WHERE account_id = $1 AND NOT told AND status <> 'pending'
           RETURNING day, meal, text, kcal, status, created_at""", account)
    if not rows:
        return ""
    head, line, bad = FOOD_NOTE[lang]
    items = [(line if r["status"] != "failed" else bad).format(meal=r["meal"], text=r["text"],
                                                                 kcal=round(r["kcal"] or 0))
             for r in sorted(rows, key=lambda r: r["created_at"])]
    day = await today(pool, account, now)
    total = L.summary(await entries_on(pool, account, day), None)["kcal"]
    return head.format(items="；".join(items) if lang == "zh" else "; ".join(items), total=total)
