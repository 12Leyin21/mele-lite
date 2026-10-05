"""表情包的接口（10-01）：TA 的库（传、改、删、取图）、从聊天里的图收一张、从面板发一张。"""
from __future__ import annotations

import asyncio
import logging
from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse

from brain import accounts, archive, attachments
from brain import stickers as S
from brain.settings import Settings

from .deps import Api, account, api, own_conversation

router = APIRouter()
log = logging.getLogger(__name__)
_BG: set[asyncio.Task] = set()


def _caption_later(a: Api, acc: UUID) -> None:
    """后台写描述（正式接口才跑；测试里不跑，免得吃掉假模型的剧本）。"""
    if not a.deps.sentinel:
        return
    t = asyncio.create_task(S.caption_pending(a.deps, acc, a.deps.now()))
    _BG.add(t)
    t.add_done_callback(_BG.discard)


async def _lang(a: Api, acc: UUID) -> str:
    comps = await accounts.list_companions(a.deps.pool, acc)
    return Settings.from_dict(await archive.get_settings(a.deps.pool, comps[0])).lang if comps else "zh"


@router.get("/stickers")
async def list_stickers(acc: UUID = Depends(account), a: Api = Depends(api)):
    return [s.to_dict() for s in await S.list_all(a.deps.pool, acc)]


@router.post("/stickers", status_code=201)
async def upload(files: list[UploadFile] = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """一次传好几张（相册多选）。返回 {added: [...], skipped: [{name, reason}]}；同一张收过的算 skipped。"""
    lang, added, skipped = await _lang(a, acc), [], []
    for f in files:
        data = await f.read(S.MAX_GIF_BYTES + 1)
        try:
            s, new = await S.add(a.deps.pool, a.deps.embedder, a.cfg.files_dir, acc, data=data, lang=lang)
        except S.StickerError as e:
            skipped.append({"name": f.filename or "", "reason": str(e)})
            continue
        (added if new else skipped).append(s.to_dict() if new else {"name": f.filename or "", "reason": "已经收过了"})
    _caption_later(a, acc)
    return {"added": added, "skipped": skipped}


@router.post("/stickers/from-attachment/{aid}", status_code=201)
async def from_attachment(aid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """聊天里长按一张图「加到表情包」（TA 发的图、TA 发的表情包都行）。"""
    att = await attachments.get(a.deps.pool, acc, aid)
    if att is None or att.kind != "image":
        raise HTTPException(404, "没有这张图")
    with open(att.path, "rb") as fh:
        data = fh.read()
    try:
        s, _ = await S.add(a.deps.pool, a.deps.embedder, a.cfg.files_dir, acc, data=data, caption=att.caption,
                           lang=await _lang(a, acc))
    except S.StickerError as e:
        raise HTTPException(400, str(e)) from e
    _caption_later(a, acc)
    return s.to_dict()


@router.patch("/stickers/{sid}")
async def patch_sticker(sid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{name?, caption?, only_for?: [联系人编号]（空 = 都能用）}"""
    try:
        only = [UUID(str(x)) for x in body["only_for"]] if "only_for" in body else None
        s = await S.update(a.deps.pool, a.deps.embedder, acc, sid, name=body.get("name"), caption=body.get("caption"),
                           only_for=only)
    except LookupError:
        raise HTTPException(404, "没有这张")
    except (S.StickerError, ValueError) as e:
        raise HTTPException(400, str(e)) from e
    return s.to_dict()


@router.delete("/stickers/{sid}", status_code=204)
async def delete_sticker(sid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await S.delete(a.deps.pool, acc, sid):
        raise HTTPException(404, "没有这张")
    return Response(status_code=204)


@router.get("/stickers/{sid}/image")
async def image(sid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    s = await S.get(a.deps.pool, acc, sid)
    if s is None:
        raise HTTPException(404, "没有这张")
    return FileResponse(s.path, media_type=s.mime)


@router.post("/conversations/{conv}/stickers/{sid}", status_code=201)
async def send_from_panel(conv: UUID, sid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    """TA 从面板点一张：变成这个窗口的一个附件，发消息时照常带 attachments: [编号]。"""
    await own_conversation(a, acc, conv)
    att = await S.to_attachment(a.deps.pool, a.cfg.files_dir, acc, conv, sid)
    if att is None:
        raise HTTPException(404, "没有这张")
    await S.mark_used(a.deps.pool, sid, a.deps.now())
    return att.public()
