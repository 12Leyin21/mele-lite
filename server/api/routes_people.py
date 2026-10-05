"""人物卡的接口（10-01）：Library「人物卡」房间里看、加、改、删，加「对谁隐藏」。卡在账号名下，大家共用。
TA 在这里改的都算 TA 写的（by=user）：它以后就改不动「是谁 / 要记得」了，只能补印象。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

import memory as M
from brain import hidden

from .deps import Api, account, api

router = APIRouter()


async def _view(pool, p) -> dict:
    return {"id": p.id, "name": p.name or "", "aliases": [x for x in p.aliases if x != p.name],
            "relation": p.relation or "", "facts": p.content or "", "impression": p.impression or "",
            "created_by": p.created_by, "updated_by": p.updated_by,
            "updated_at": p.updated_at.isoformat() if p.updated_at else None,
            "hidden_from": [str(c) for c in await hidden.hidden_from(pool, p.id)]}


def _ids(v) -> list[UUID]:
    try:
        return [UUID(str(x)) for x in (v or [])]
    except ValueError:
        raise HTTPException(400, "hidden_from 里有不认识的联系人") from None


async def _card(pool, acc: UUID, pid: int):
    p = next((x for x in await M.list_people(pool, acc) if x.id == pid), None)
    if p is None:
        raise HTTPException(404, "没有这张卡")
    return p


@router.get("/people")
async def list_people(acc: UUID = Depends(account), a: Api = Depends(api)):
    return [await _view(a.deps.pool, p) for p in await M.list_people(a.deps.pool, acc)]


@router.post("/people", status_code=201)
async def add_person(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{name, relation?, facts?, aliases?, impression?, hidden_from?: [联系人 id]}"""
    pool, name = a.deps.pool, str(body.get("name") or "").strip()
    if any((p.name or "").lower() == name.lower() for p in await M.list_people(pool, acc)):
        raise HTTPException(409, "已经有这个人了，去改那张卡")
    try:
        p = await M.upsert_person(pool, a.deps.embedder, acc, name, relation=body.get("relation"), facts=body.get("facts"),
                                  impression=body.get("impression"), aliases=body.get("aliases") or [], by="user",
                                  now=a.deps.now())
    except ValueError as e:
        raise HTTPException(400, "名字是空的" if "name" in str(e) else str(e)) from e
    if "hidden_from" in body:
        await hidden.set_hidden(pool, acc, p.id, _ids(body["hidden_from"]))
    return await _view(pool, p)


@router.patch("/people/{pid}")
async def patch_person(pid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """给了的字段整个换掉（别名也是换），没给的不动；hidden_from 给了就整个换。"""
    pool = a.deps.pool
    await _card(pool, acc, pid)
    kw = {k: body[k] for k in ("name", "aliases", "relation", "facts", "impression") if k in body}
    if kw:
        try:
            await M.update_person(pool, a.deps.embedder, acc, pid, by="user", now=a.deps.now(), **kw)
        except ValueError as e:
            raise HTTPException(400, "名字是空的") from e
    if "hidden_from" in body:
        await hidden.set_hidden(pool, acc, pid, _ids(body["hidden_from"]))
    return await _view(pool, await _card(pool, acc, pid))


@router.delete("/people/{pid}", status_code=204)
async def delete_person(pid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _card(a.deps.pool, acc, pid)
    await M.delete(a.deps.pool, acc, pid)
    return Response(status_code=204)
