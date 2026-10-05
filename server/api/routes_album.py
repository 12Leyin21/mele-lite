"""相册的接口（10-02）：三本的列表、取图、TA 加照片、收藏 / 隐私、删。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse

from brain import accounts
from brain import album as A

from .deps import Api, account, api, own_companion

router = APIRouter()


@router.get("/album")
async def list_album(book: str = "all", companion_id: UUID | None = None, acc: UUID = Depends(account),
                     a: Api = Depends(api)):
    """book = all（不含隐私）/ starred / secret（隐私那本，App 先过 Face ID 再要）"""
    try:
        return [p.public() for p in await A.list_all(a.deps.pool, acc, book=book, companion=companion_id)]
    except A.AlbumError as e:
        raise HTTPException(400, str(e)) from e


@router.get("/album/{pid}/image")
async def image(pid: int, thumb: bool = False, acc: UUID = Depends(account), a: Api = Depends(api)):
    """thumb=1：长边 480 的小图（胶片和宫格用，第一次要的时候做一张存着）"""
    p = await A.get(a.deps.pool, acc, pid)
    if p is None:
        raise HTTPException(404, "没有这张")
    path = A.thumb(p.path) if thumb else p.path
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=604800"})


@router.post("/album", status_code=201)
async def add(files: list[UploadFile] = File(...), note: str = Form(""), companion_id: UUID | None = Form(None),
              acc: UUID = Depends(account), a: Api = Depends(api)):
    """TA 自己加照片（最多 9 张 + 一段话），给哪个联系人看（不填 = 主联系人）。一分钟后它看。"""
    comps = await accounts.list_companions(a.deps.pool, acc)
    comp = await own_companion(a, acc, companion_id) if companion_id else comps[0]
    data = [await f.read() for f in files]
    try:
        got = await A.add_mine(a.deps.pool, a.cfg.files_dir, acc, comp, data, note, a.deps.now())
    except A.AlbumError as e:
        raise HTTPException(400, str(e)) from e
    return [p.public() for p in got]


@router.patch("/album/{pid}")
async def patch(pid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{starred?, secret?}"""
    p = await A.set_flags(a.deps.pool, acc, pid,
                          starred=bool(body["starred"]) if "starred" in body else None,
                          secret=bool(body["secret"]) if "secret" in body else None)
    if p is None:
        raise HTTPException(404, "没有这张")
    return p.public()


@router.delete("/album/{pid}", status_code=204)
async def delete(pid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await A.delete(a.deps.pool, acc, pid):
        raise HTTPException(404, "没有这张")
    return Response(status_code=204)
