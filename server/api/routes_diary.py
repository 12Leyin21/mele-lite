"""日记的接口（10-01）：两本一起列；TA 写 / 改 / 删自己的；拿 Ta 给的钥匙打开锁着那段。钥匙永远不在列表里，只在这里核对。"""
from __future__ import annotations

from datetime import date
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.responses import JSONResponse

from brain import accounts, archive
from brain import diary as DY
from brain.settings import Settings

from .deps import Api, account, api

router = APIRouter()


def _day(v) -> date | None:
    if not v:
        return None
    try:
        return date.fromisoformat(str(v))
    except ValueError:
        raise HTTPException(400, "日期要写成 YYYY-MM-DD")


async def _today(pool, acc: UUID, now) -> date:
    comps = await accounts.list_companions(pool, acc)
    tz = Settings.from_dict(await archive.get_settings(pool, comps[0])).tz if comps else "UTC"
    return now.astimezone(ZoneInfo(tz)).date()


def _mine(e: DY.Entry) -> dict:
    return {"id": e.id, "author": "user", "day": e.day.isoformat(), "body": e.body, "private": e.private,
            "margin": e.margin, "written_at": e.created_at.isoformat(), "updated_at": e.updated_at.isoformat()}


@router.get("/diary")
async def list_diary(before: str | None = None, limit: int = 30, acc: UUID = Depends(account), a: Api = Depends(api)):
    return await DY.list_for_account(a.deps.pool, acc, before=_day(before), limit=limit)


@router.post("/diary")
async def write(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{body, day?, private?}：day 不填 = TA 那边的今天。"""
    pool, now = a.deps.pool, a.deps.now()
    day = _day(body.get("day")) or await _today(pool, acc, now)
    try:
        e = await DY.write_mine(pool, acc, day=day, body=str(body.get("body") or ""), private=bool(body.get("private")),
                                now=now)
    except ValueError as err:
        raise HTTPException(400, str(err))
    return _mine(e)


@router.patch("/diary/{entry_id}")
async def edit(entry_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        e = await DY.edit_mine(a.deps.pool, acc, entry_id,
                               body=str(body["body"]) if "body" in body else None,
                               private=bool(body["private"]) if "private" in body else None,
                               day=_day(body.get("day")), now=a.deps.now())
    except ValueError as err:
        raise HTTPException(400, str(err))
    except LookupError:
        raise HTTPException(404, "没有这篇")
    return _mine(e)


@router.delete("/diary/{entry_id}", status_code=204)
async def delete(entry_id: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await DY.delete_mine(a.deps.pool, acc, entry_id):
        raise HTTPException(404, "没有这篇")


@router.post("/diary/{entry_id}/unlock")
async def unlock(entry_id: int, body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{code}：错了 403 带 left；锁着 423 带 wait_seconds；Ta 还没给过钥匙 / 没锁东西 409；对了 200 带锁着那段。"""
    status, got = await DY.unlock(a.deps.pool, acc, entry_id, str(body.get("code") or ""), a.deps.now())
    if status == "missing":
        raise HTTPException(404, "没有这篇")
    if status == "wrong":
        return JSONResponse({"detail": f"密码不对，还能再试 {got} 次", "left": got}, status_code=403)
    if status == "locked":
        return JSONResponse({"detail": f"输错太多次了，{max(1, -(-got // 60))} 分钟以后再试", "wait_seconds": got},
                            status_code=423)
    if status == "sealed":
        return JSONResponse({"detail": "还没拿到钥匙，去问 Ta 要"}, status_code=409)
    if status == "nothing":
        return JSONResponse({"detail": "这篇没有锁着的段"}, status_code=409)
    return {"id": got.id, "locked": got.locked}
