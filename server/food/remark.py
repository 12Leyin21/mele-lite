"""记一餐，Lumi 说一句（09-30，设计 specs/2026-09-30-meal-remark-design.md；Tilia定：默认开、不等估算、每次都说）。

TA 在饮食页自己记的（app 来的）才算：记完挂一个一分钟后响的一次性钟（kind='meal'），这一分钟里又记的合成一次说。
钟响走巡逻的醒来流程（一定开口）；〔醒来〕里写这几样吃了什么、几点，今天前面吃过的，天气——**不给热量**，它就算不了卡路里。"""
from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from brain import accounts, context_line

from . import store as S

WAIT = timedelta(minutes=1)


async def arm(pool, account: UUID, entry_id: int, now: datetime) -> None:
    """TA 在饮食页记了一条：标成「还没说过」，主联系人没有正等着响的饭钟就挂一个。"""
    if not (await S.settings(pool, account)).get("remark", True):
        return
    comps = await accounts.list_companions(pool, account)
    if not comps:
        return
    await pool.execute("UPDATE food_entries SET remarked = FALSE WHERE id = $1 AND account_id = $2", entry_id, account)
    waiting = await pool.fetchval("SELECT 1 FROM clocks WHERE companion_id = $1 AND kind = 'meal' AND next_at IS NOT NULL",
                                  comps[0])
    if not waiting:
        from patrol import store as clock_store                 # 巡逻那边的，用到时才引
        at = now + WAIT
        await clock_store.add_clock(pool, account, comps[0], kind="meal", shape="once", spec={"at": at.isoformat()},
                                    note="", next_at=at)


def _line(r, tz: str, lang: str) -> str:
    t = r["created_at"].astimezone(ZoneInfo(tz)).strftime("%H:%M")
    what = r["text"] + (f"（{r['detail']}）" if lang == "zh" and r["detail"] else f" ({r['detail']})" if r["detail"] else "")
    pic = ("（拍了照片）" if lang == "zh" else " (with a photo)") if r["photos"] else ""
    return f"- {t} {r['meal']}：{what}{pic}" if lang == "zh" else f"- {t} {r['meal']}: {what}{pic}"


async def mark_said(pool, ids: list[int]) -> None:
    """醒来那轮真跑了才标（跑之前 TA 抢先开口、推迟一分钟的，下次照样说）。"""
    await pool.execute("UPDATE food_entries SET remarked = TRUE WHERE id = ANY($1::bigint[])", ids)


async def wake_note(pool, account: UUID, now: datetime, tz: str, lang: str) -> tuple[str, list[int]] | None:
    """钟响时拼〔醒来〕里那段，连同这几条的编号（跑完交给 mark_said）。没有还没说过的（都删了）= None。"""
    cols = ("e.id, e.meal, e.text, e.detail, e.created_at, "
            "EXISTS (SELECT 1 FROM food_photos p WHERE p.entry_id = e.id) AS photos")
    fresh = await pool.fetch(f"SELECT {cols} FROM food_entries e WHERE e.account_id = $1 AND NOT e.remarked "
                             "ORDER BY e.created_at, e.id", account)
    if not fresh:
        return None
    today = await S.today(pool, account, now)
    earlier = await pool.fetch(f"SELECT {cols} FROM food_entries e WHERE e.account_id = $1 AND e.day = $2 "
                               "AND NOT (e.id = ANY($3::bigint[])) ORDER BY e.created_at, e.id",
                               account, today, [r["id"] for r in fresh])
    zh = lang == "zh"
    out = [("TA 刚在饮食页记了：" if zh else "They just logged:")] + [_line(r, tz, lang) for r in fresh]
    if earlier:
        out += [("今天前面吃过：" if zh else "Earlier today:")] + [_line(r, tz, lang) for r in earlier]
    items = await context_line.load(pool, account)
    if "weather" in items and now - items["weather"][1] <= context_line.MAX_AGE["weather"]:
        w = context_line._weather(items["weather"][0], lang)
        if w:
            out.append(f"{'天气' if zh else 'Weather'}：{w}" if zh else f"Weather: {w}")
    return "\n".join(out), [r["id"] for r in fresh]
