"""世界书的接口（09-30）：TA 在 Library「世界书」里看、加、改、删。TA 能改任何一条（包括它记的）。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import lore as L

from .deps import Api, account, api, own_companion

router = APIRouter()


async def _target(a: Api, acc: UUID, body: dict) -> UUID | None:
    """给谁：companion_id = 某个联系人；空 / 不写 = 所有联系人都知道。"""
    cid = body.get("companion_id")
    if not cid:
        return None
    try:
        return await own_companion(a, acc, UUID(str(cid)))
    except ValueError:
        raise HTTPException(400, "companion_id 不对") from None


@router.get("/lore")
async def list_lore(companion_id: str = "", acc: UUID = Depends(account), a: Api = Depends(api)):
    """不带 companion_id = 全部；带 = 那个联系人看得到的（它的 + 共享的）。"""
    cid = await _target(a, acc, {"companion_id": companion_id})
    return [e.as_dict() for e in await L.list_for(a.deps.pool, acc, cid)]


@router.post("/lore", status_code=201)
async def add_lore(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{name, keywords: [..] 或 "a, b", content, companion_id?（空 = 所有人）, enabled?, constant?}"""
    cid = await _target(a, acc, body)
    try:
        e = await L.add(a.deps.pool, acc, companion_id=cid, name=body.get("name"), keywords=body.get("keywords"),
                        content=body.get("content"), created_by="user", enabled=body.get("enabled", True) is not False,
                        constant=bool(body.get("constant")))
    except ValueError as ex:
        raise HTTPException(400, str(ex)) from ex
    return e.as_dict()


@router.patch("/lore/{entry_id}")
async def patch_lore(entry_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """改一部分；带 companion_id 键才改给谁（null = 所有人）。"""
    kw = {k: body[k] for k in ("name", "keywords", "content", "enabled", "constant") if k in body}
    if "companion_id" in body:
        kw["companion_id"] = await _target(a, acc, body)
    try:
        e = await L.update(a.deps.pool, acc, entry_id, **kw)
    except ValueError as ex:
        raise HTTPException(400, str(ex)) from ex
    if e is None:
        raise HTTPException(404, "没有这一条")
    return e.as_dict()


@router.delete("/lore/{entry_id}", status_code=204)
async def delete_lore(entry_id: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await L.delete(a.deps.pool, acc, entry_id):
        raise HTTPException(404, "没有这一条")
    return Response(status_code=204)
