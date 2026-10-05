"""Mele Host（10-04）：自己部署的单人服务器。
/version 给 App 判断连的是不是 Host、接口版本对不对得上；/host/pair 用配对码换登录凭证；
/me/import 收 Lite 手机里搬来的东西（第三步）；带文件的房间先 /me/import/files 问缺哪些、一个个 PUT 上来。
/companions/{id}/import 收别的 AI 的官方聊天记录（10-05，brain/chat_import.py；包在手机上认好再发来）。"""
from __future__ import annotations

from datetime import timedelta
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response

from brain import auth, chat_import, host, host_import

from .deps import Api, account, api, own_companion

router = APIRouter()
LOCK_AFTER = 5                      # 连错几次锁一会儿（8 位码猜不中，这里只是防有人一直敲）
LOCK_FOR = timedelta(minutes=10)


@router.get("/version")
async def version(a: Api = Depends(api)):
    from .app import API_VERSION
    return {"api": API_VERSION, "host": a.cfg.host_mode}


@router.post("/host/pair")
async def pair(body: dict = Body(...), a: Api = Depends(api)):
    if not a.cfg.host_mode:
        raise HTTPException(404, "这不是 Mele Host")
    now = a.deps.now()
    misses = a.app_state.setdefault("pair_misses", [])
    misses[:] = [t for t in misses if now - t < LOCK_FOR]
    if len(misses) >= LOCK_AFTER:
        raise HTTPException(429, "错太多次了，十分钟后再试")
    try:
        acc = await host.pair(a.deps.pool, str(body.get("code") or ""), secret=a.cfg.secret, now=now,
                              tz=str(body.get("tz") or "UTC"))
    except host.PairError as e:
        misses.append(now)
        raise HTTPException(400, str(e)) from e
    misses.clear()
    token = await auth.new_session(a.deps.pool, acc, secret=a.cfg.secret, now=now)
    from .routes_account import _me
    return {"token": token, "account": await _me(a, acc)}


@router.post("/me/import")
async def import_from_phone(body: dict = Body(...), acc=Depends(account), a: Api = Depends(api)):
    """Lite 搬家：整包一次收（brain/host_import.py）。只有 Host 收；同一个包再发一次不会重复。"""
    if not a.cfg.host_mode:
        raise HTTPException(404, "这不是 Mele Host")
    try:
        return await host_import.run(a.deps.pool, a.cfg.box, acc, body, files_dir=a.cfg.files_dir, now=a.deps.now(),
                                     embedder=a.deps.embedder)
    except host_import.ImportError_ as e:
        raise HTTPException(400, str(e)) from e


@router.post("/me/import/files")
async def import_files_needed(body: dict = Body(...), acc=Depends(account), a: Api = Depends(api)):
    """搬家前先问：包里的房间（body.rooms）还缺哪些文件（指纹）。搬过的、已经传上来的不要。"""
    if not a.cfg.host_mode:
        raise HTTPException(404, "这不是 Mele Host")
    rooms = body.get("rooms") if isinstance(body.get("rooms"), dict) else {}
    return {"missing": await host_import.needed(a.deps.pool, acc, a.cfg.files_dir, rooms)}


@router.put("/me/import/files/{sha}", status_code=204)
async def import_file(sha: str, request: Request, acc=Depends(account), a: Api = Depends(api)):
    """传一个文件进暂存（原始字节；指纹对不上就不收）。下一次 /me/import 用掉后清空。"""
    if not a.cfg.host_mode:
        raise HTTPException(404, "这不是 Mele Host")
    data = b""
    async for chunk in request.stream():
        data += chunk
        if len(data) > host_import.STAGE_MAX:
            raise HTTPException(413, "文件太大了（最多 25MB）")
    try:
        host_import.stage(a.cfg.files_dir, sha, data)
    except host_import.ImportError_ as e:
        raise HTTPException(400, str(e)) from e
    return Response(status_code=204)


@router.post("/companions/{cid}/import", status_code=201)
async def import_chats(cid: UUID, body: dict = Body(...), acc=Depends(account), a: Api = Depends(api)):
    """搬别的 AI 的聊天：{source, conversations: [{title, messages: [{role, text, at}]}], extra, memories}"""
    await own_companion(a, acc, cid)
    try:
        return await chat_import.start(a.deps, acc, cid, body)
    except chat_import.ImportError_ as e:
        raise HTTPException(400, str(e)) from e


@router.get("/companions/{cid}/import")
async def import_chats_status(cid: UUID, acc=Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    return await chat_import.status(a.deps, acc, cid)
