"""记着的远事的接口（09-28）：TA 在「它记着的事」里看、加、改、删。只列没了结的。"""
from __future__ import annotations

from datetime import date
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import archive
from brain import far_dates as FD
from brain.settings import Settings

from .deps import Api, account, api, own_companion

router = APIRouter()


async def _settings(a: Api, cid: UUID) -> Settings:
    return Settings.from_dict(await archive.get_settings(a.deps.pool, cid))


def _item(f: FD.FarDate, today: date) -> dict:
    return {"id": f.id, "companion_id": str(f.companion_id), "day": f.day.isoformat(), "time": f.at_time,
            "title": f.title, "note": f.note, "days_left": (f.day - today).days}


def _day(v) -> date:
    try:
        return date.fromisoformat(str(v or ""))
    except ValueError:
        raise HTTPException(400, "day 要写成 YYYY-MM-DD") from None


@router.get("/companions/{cid}/dates")
async def list_dates(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    today = a.deps.now().astimezone(ZoneInfo((await _settings(a, cid)).tz)).date()
    return [_item(f, today) for f in await FD.list_open(a.deps.pool, acc, cid)]


@router.post("/companions/{cid}/dates", status_code=201)
async def add_date(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{day: YYYY-MM-DD, time?: HH:MM, title, note?}"""
    await own_companion(a, acc, cid)
    s, now = await _settings(a, cid), a.deps.now()
    try:
        f = await FD.add(a.deps.pool, acc, cid, s, day=_day(body.get("day")), at_time=str(body.get("time") or ""),
                         title=str(body.get("title") or ""), note=str(body.get("note") or ""), now=now)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    return _item(f, now.astimezone(ZoneInfo(s.tz)).date())


@router.patch("/dates/{date_id}")
async def patch_date(date_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    f = await FD.get(a.deps.pool, acc, date_id)
    if f is None or f.resolved_at is not None:
        raise HTTPException(404, "没有这件")
    s, now = await _settings(a, f.companion_id), a.deps.now()
    try:
        g = await FD.update(a.deps.pool, acc, date_id, s, day=_day(body["day"]) if "day" in body else None,
                            at_time=str(body.get("time") or "") if "time" in body else FD._KEEP,
                            title=body.get("title"), note=body.get("note"), now=now)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    return _item(g, now.astimezone(ZoneInfo(s.tz)).date())


@router.delete("/dates/{date_id}", status_code=204)
async def delete_date(date_id: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await FD.delete(a.deps.pool, acc, date_id):
        raise HTTPException(404, "没有这件")
    return Response(status_code=204)
