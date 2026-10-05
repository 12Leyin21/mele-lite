"""朋友圈的接口（10-01，移植自之前自用的 App）：刷、发（带图）、删、赞、评论、签名、封面、取图。"""
from __future__ import annotations

import asyncio
from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse

from brain import accounts
from brain import moments as MO
from brain.attachments import AttachmentError

from .deps import Api, account, api

router = APIRouter()


async def _who_ok(a: Api, acc: UUID, who: str) -> str:
    if who == MO.USER:
        return who
    try:
        cid = UUID(who)
    except ValueError:
        raise HTTPException(404, "没有这个人")
    if cid not in await accounts.list_companions(a.deps.pool, acc):
        raise HTTPException(404, "没有这个人")
    return who


@router.get("/moments")
async def feed(who: str | None = None, before: int | None = None, limit: int = 20, acc: UUID = Depends(account),
               a: Api = Depends(api)):
    """刷：全部（who 不填）或某一个人的主页（who=user / 联系人编号）。"""
    if who:
        await _who_ok(a, acc, who)
    nm = await MO.names(a.deps.pool, acc)
    return [MO.to_dict(m, nm) for m in await MO.feed(a.deps.pool, acc, author=who, before=before, limit=limit)]


@router.get("/moments/activity")
async def activity(since: str | None = None, acc: UUID = Depends(account), a: Api = Depends(api)):
    """since = 上次看过的时间（ISO）；不填 = 全部。"""
    from datetime import datetime
    try:
        at = datetime.fromisoformat(since) if since else None
    except ValueError:
        raise HTTPException(400, "since 要是 ISO 时间")
    return await MO.activity(a.deps.pool, acc, at)


@router.post("/moments", status_code=201)
async def post(content: str = Form(""), files: list[UploadFile] = File(default=[]), acc: UUID = Depends(account),
               a: Api = Depends(api)):
    images = []
    for f in files[:MO.MAX_IMAGES]:
        try:
            images.append(MO.save_image(a.cfg.files_dir, await f.read(10 * 1024 * 1024 + 1)))
        except AttachmentError as e:
            raise HTTPException(400, str(e)) from e
    try:
        m = await MO.post(a.deps.pool, acc, MO.USER, content=content, images=images, now=a.deps.now())
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    return MO.to_dict(m, await MO.names(a.deps.pool, acc))


@router.delete("/moments/{mid}", status_code=204)
async def delete(mid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await MO.delete(a.deps.pool, acc, mid):
        raise HTTPException(404, "没有这条（只能删自己发的）")
    return Response(status_code=204)


@router.post("/moments/{mid}/like")
async def like(mid: int, body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await MO.like(a.deps.pool, acc, mid, MO.USER, bool(body.get("liked", True)), now=a.deps.now()):
        raise HTTPException(404, "没有这条")
    return MO.to_dict(await MO.get(a.deps.pool, acc, mid), await MO.names(a.deps.pool, acc))


@router.post("/moments/{mid}/comments", status_code=201)
async def comment(mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{content, reply_to?}：评在它的动态下、或者回它的评论，它到点会来回。"""
    rt = body.get("reply_to")
    try:
        await MO.comment(a.deps.pool, acc, mid, MO.USER, str(body.get("content") or ""), now=a.deps.now(),
                         reply_to=int(rt) if rt else None)
    except LookupError:
        raise HTTPException(404, "没有这条")
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    return MO.to_dict(await MO.get(a.deps.pool, acc, mid), await MO.names(a.deps.pool, acc))


@router.delete("/moments/comments/{cid}", status_code=204)
async def delete_comment(cid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await MO.delete_comment(a.deps.pool, acc, cid):
        raise HTTPException(404, "没有这条评论（只能删自己的）")
    return Response(status_code=204)


@router.get("/moments/{mid}/images/{n}")
async def image(mid: int, n: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    m = await MO.get(a.deps.pool, acc, mid)
    if m is None or not 0 <= n < len(m.images):
        raise HTTPException(404, "没有这张")
    return FileResponse(m.images[n]["path"], media_type=m.images[n].get("mime", "image/jpeg"))


@router.get("/moments/profile/{who}")
async def profile(who: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _who_ok(a, acc, who)
    p = await MO.profile(a.deps.pool, acc, who)
    nm = await MO.names(a.deps.pool, acc)
    return {"who": who, "name": nm.get(who, ""), "signature": p["signature"], "has_cover": bool(p["cover_path"])}


@router.put("/moments/profile/user/signature")
async def signature(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """TA 的签名（封面头像下面，点一下改）。联系人的签名它自己用工具改。"""
    return {"signature": await MO.set_signature(a.deps.pool, acc, MO.USER, str(body.get("signature") or ""))}


@router.put("/moments/profile/{who}/cover")
async def cover(who: str, file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """换封面（TA 的，也能替联系人换）。"""
    await _who_ok(a, acc, who)
    from brain.attachments import _image
    try:
        blob = _image(await file.read(10 * 1024 * 1024 + 1))
    except AttachmentError as e:
        raise HTTPException(400, str(e)) from e
    await MO.set_cover(a.deps.pool, a.cfg.files_dir, acc, who, blob)
    return Response(status_code=204)


@router.get("/moments/profile/{who}/cover")
async def get_cover(who: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _who_ok(a, acc, who)
    p = (await MO.profile(a.deps.pool, acc, who))["cover_path"]
    if not p:
        raise HTTPException(404, "还没有封面")
    return FileResponse(p, media_type="image/jpeg")
