"""上传照片和文件、取图（iOS 第一块第 3 步）。附件只属于上传它的账号，别人拿编号来一律 404。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse

from brain import attachments

from .deps import Api, account, api, own_conversation

router = APIRouter()


@router.post("/conversations/{conv}/attachments", status_code=201)
async def upload(conv: UUID, file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """传一张图或一个文件，拿回编号；发消息时带上 attachments: [编号]。"""
    await own_conversation(a, acc, conv)
    data = await file.read(attachments.FILE_MAX_BYTES + 1)
    try:
        att = await attachments.save(a.deps.pool, a.cfg.files_dir, account=acc, conversation=conv,
                                     name=file.filename or "", mime=file.content_type or "", data=data)
    except attachments.AttachmentError as e:
        raise HTTPException(400, str(e)) from e
    return att.public()


@router.get("/attachments/{aid}")
async def fetch(aid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    att = await attachments.get(a.deps.pool, acc, aid)
    if att is None:
        raise HTTPException(404, "没有这个附件")
    return FileResponse(att.path, media_type=att.mime, filename=att.name or None)
