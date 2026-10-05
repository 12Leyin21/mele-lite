"""收藏夹的接口（10-02）：列表、收（一条或一组）、取消（按编号 / 按气泡 / 整组）。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import favorites as F

from .deps import Api, account, api

router = APIRouter()


@router.get("/favorites")
async def list_favorites(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await F.list_all(a.deps.pool, acc)


@router.post("/favorites", status_code=201)
async def add(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{items: [{message_id, slot, text, with_files?}], group?: bool} → 新收的那几条（收过的不在里面）"""
    try:
        return await F.add(a.deps.pool, acc, list(body.get("items") or []), group=bool(body.get("group")), now=a.deps.now())
    except F.FavoriteError as e:
        raise HTTPException(400, str(e)) from e


@router.delete("/favorites/{fid}", status_code=204)
async def remove(fid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await F.remove(a.deps.pool, acc, fid):
        raise HTTPException(404, "没有这条收藏")
    return Response(status_code=204)


@router.delete("/favorites/bubble/{mid}/{slot}", status_code=204)
async def remove_bubble(mid: int, slot: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    """聊天里长按「取消收藏」：手机只知道是哪个气泡"""
    if not await F.remove_bubble(a.deps.pool, acc, mid, slot):
        raise HTTPException(404, "这句没收藏")
    return Response(status_code=204)


@router.delete("/favorites/group/{gid}", status_code=204)
async def remove_group(gid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await F.remove_group(a.deps.pool, acc, gid):
        raise HTTPException(404, "没有这组")
    return Response(status_code=204)
