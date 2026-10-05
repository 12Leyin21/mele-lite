"""饮食的接口（09-29，搬自 fed-myself 的 /food/*，改成按账号）。照片先 POST /food/photo 拿编号，再放进条目的 photos。"""
from __future__ import annotations

from datetime import date
from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, HTTPException, Response, UploadFile

from brain import attachments
from food import estimate
from food import logic as L
from food import off
from food import remark
from food import store as S

from .deps import Api, account, api

router = APIRouter()


def _day(v) -> date | None:
    if not v:
        return None
    try:
        return date.fromisoformat(str(v))
    except ValueError:
        raise HTTPException(400, "日期要写成 YYYY-MM-DD") from None


@router.get("/food/days")
async def days(limit: int = 60, q: str = "", acc: UUID = Depends(account), a: Api = Depends(api)):
    return await S.days(a.deps.pool, acc, limit=limit, q=q)


@router.get("/food/day/{d}")
async def day(d: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    return await S.day_view(a.deps.pool, acc, _day(d))


@router.post("/food/entry", status_code=201)
async def add(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{meal, text, detail?, kcal?, protein?, carbs?, fat?, photos?: [编号], day?, ext_id?, source?}；没 kcal = 待估。"""
    pool = a.deps.pool
    d = _day(body.get("day")) or await S.today(pool, acc, a.deps.now())
    try:
        e = await S.add(pool, acc, body, day=d, source="watch" if body.get("source") == "watch" else "app", now=a.deps.now())
    except S.FoodError as err:
        raise HTTPException(400, str(err)) from err
    if e["status"] == "pending":
        estimate.schedule(a.deps, acc, e["id"])            # 一提交就在后台估（Tilia 09-29 选 A）
    if e["source"] == "app":
        await remark.arm(pool, acc, e["id"], a.deps.now())  # 一分钟后 Lumi 说一句（09-30）
    return e


@router.patch("/food/entry/{eid}")
async def edit(eid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        e = await S.update(a.deps.pool, acc, eid, body)
    except S.FoodError as err:
        raise HTTPException(400, str(err)) from err
    if e is None:
        raise HTTPException(404, "没有这条")
    if e["status"] == "pending":
        estimate.schedule(a.deps, acc, eid)
    return e


@router.delete("/food/entry/{eid}", status_code=204)
async def delete(eid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await S.delete(a.deps.pool, acc, eid):
        raise HTTPException(404, "没有这条")
    return Response(status_code=204)


@router.post("/food/photo", status_code=201)
async def photo(file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """传一张照片，拿回编号（饮食的照片不挂在哪个窗口；取图照样走 GET /attachments/{编号}）。"""
    data = await file.read(attachments.FILE_MAX_BYTES + 1)
    try:
        att = await attachments.save(a.deps.pool, a.cfg.files_dir, account=acc, conversation=None,
                                     name=file.filename or "photo.jpg", mime=file.content_type or "image/jpeg", data=data)
    except attachments.AttachmentError as e:
        raise HTTPException(400, str(e)) from e
    if att.kind != "image":
        raise HTTPException(400, "饮食只收照片")
    return {"id": str(att.id), "url": f"/attachments/{att.id}"}


@router.get("/food/settings")
async def get_settings(acc: UUID = Depends(account), a: Api = Depends(api)):
    s = await S.settings(a.deps.pool, acc)
    return {**s, "targets": L.targets(s)}


@router.put("/food/settings")
async def put_settings(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        s = await S.save_settings(a.deps.pool, acc, body)
    except (S.FoodError, TypeError, ValueError, KeyError) as e:
        raise HTTPException(400, str(e) or "设置不对") from e
    return {**s, "targets": L.targets(s)}


@router.post("/food/cover", status_code=204)
async def cover(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    d = _day(body.get("date"))
    if d is None:
        raise HTTPException(400, "要带 date")
    try:
        await S.set_cover(a.deps.pool, acc, d, str(body.get("url") or body.get("id") or "").rsplit("/", 1)[-1])
    except S.FoodError as e:
        raise HTTPException(400, str(e)) from e
    return Response(status_code=204)


@router.get("/food/barcode/{code}")
async def barcode(code: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        return await off.barcode(code, a.deps.off_get)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@router.get("/food/lookup")
async def lookup(q: str = "", country: str = "", limit: int = 5, acc: UUID = Depends(account), a: Api = Depends(api)):
    """按名字查（country 空 = 用设置里的国家，没设 = 全球）。app 的「搜名字」要 12 条，Lumi 要几条。"""
    country = country or (await S.settings(a.deps.pool, acc)).get("country") or "world"
    try:
        return await off.search(q, country, limit, a.deps.off_get)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except off.OffDown as e:
        raise HTTPException(502, str(e)) from e
