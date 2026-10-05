"""抽屉的接口（09-28）：TA 看信封、拆信。正文和密码永远不在列表里；密码只在这里核对。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.responses import JSONResponse

from brain import archive
from brain import drawer as D
from brain.persona import Persona

from .deps import Api, account, api

router = APIRouter()


@router.get("/drawer")
async def list_drawer(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await D.list_for_account(a.deps.pool, acc, a.deps.now())


@router.post("/drawer/{letter_id}/open")
async def open_letter(letter_id: int, body: dict = Body(default={}), acc: UUID = Depends(account),
                      a: Api = Depends(api)):
    """{code?}：到日子了或者开过了不用码。错了 403 带 left；锁着 423 带 wait_seconds；没到日子也没钥匙 409。"""
    pool = a.deps.pool
    status, got = await D.open_letter(pool, acc, letter_id, str(body.get("code") or ""), a.deps.now())
    if status == "missing":
        raise HTTPException(404, "没有这封")
    if status == "wrong":
        return JSONResponse({"detail": f"密码不对，还能再试 {got} 次", "left": got}, status_code=403)
    if status == "locked":
        return JSONResponse({"detail": f"输错太多次了，{max(1, -(-got // 60))} 分钟以后再试", "wait_seconds": got},
                            status_code=423)
    if status == "sealed":
        return JSONResponse({"detail": "还没到日子，也还没拿到钥匙"}, status_code=409)
    letter = got
    name = Persona.from_dict(await archive.get_persona(pool, letter.companion_id)).name
    return {"id": letter.id, "companion_id": str(letter.companion_id), "from": name, "title": letter.title,
            "content": letter.content, "written_at": letter.created_at.isoformat(),
            "unlock_at": letter.unlock_at.isoformat() if letter.unlock_at else None,
            "opened_at": letter.opened_at.isoformat()}
