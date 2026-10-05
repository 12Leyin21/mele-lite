"""塔罗的接口（10-03）：牌阵、牌名关键词、洗牌、存一局（存完马上后台解）、列表、单局、追问、重解、删。"""
from __future__ import annotations

import asyncio
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import accounts, archive
from brain import tarot as T
from brain import tarot_cards as TC
from brain import tarot_read as TR
from brain import tarot_spreads as TS
from brain.settings import Settings

from .deps import Api, account, api, own_companion

router = APIRouter()
_running: set[asyncio.Task] = set()        # 后台解牌的任务：拿住引用，免得半路被回收


async def _lang(pool, acc: UUID) -> str:
    first = (await accounts.list_companions(pool, acc))[0]
    return Settings.from_dict(await archive.get_settings(pool, first)).lang


def _kick(a: Api, acc: UUID, rid: int, followup: int | None = None) -> None:
    t = asyncio.create_task(TR.read_now(a.deps, acc, rid, followup=followup))
    _running.add(t)
    t.add_done_callback(_running.discard)


async def _own(a: Api, acc: UUID, rid: int) -> T.Reading:
    r = await T.get(a.deps.pool, acc, rid)
    if r is None:
        raise HTTPException(404, "没有这一局")
    return r


@router.get("/tarot/spreads")
async def spreads(acc: UUID = Depends(account), a: Api = Depends(api)):
    return TS.public(await _lang(a.deps.pool, acc))


@router.get("/tarot/cards")
async def cards(acc: UUID = Depends(account), a: Api = Depends(api)):
    return TC.public(await _lang(a.deps.pool, acc))


@router.post("/tarot/deck", status_code=201)
async def deck(body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{trail}：TA 手搓洗牌的指尖轨迹，混进种子。返回整副牌序（TA 点哪张是哪张，手机按下标交回来）。"""
    did, d = await T.new_deck(a.deps.pool, acc, str(body.get("trail") or ""), a.deps.now())
    return {"deck_id": did, "deck": d}


@router.post("/tarot/readings", status_code=201)
async def create(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{deck_id, spread, question, reader: 联系人 id 或 null（解牌人）, from: 问牌时所在的联系人, picks, mode}"""
    pool = a.deps.pool
    comps = await accounts.list_companions(pool, acc)
    src = await own_companion(a, acc, UUID(body["from"])) if body.get("from") else comps[0]
    reader = await own_companion(a, acc, UUID(body["reader"])) if body.get("reader") else None
    lang = Settings.from_dict(await archive.get_settings(pool, reader or src)).lang
    try:
        r = await T.save(pool, acc, deck_id=int(body.get("deck_id") or 0), spread=str(body.get("spread") or ""),
                         question=str(body.get("question") or ""), reader=reader, route_from=src,
                         picks=list(body.get("picks") or []), mode=str(body.get("mode") or ""), now=a.deps.now(),
                         lang=lang)
    except T.TarotError as e:
        raise HTTPException(400, str(e)) from e
    _kick(a, acc, r.id)
    return r.public(lang)


@router.get("/tarot/readings")
async def list_readings(companion_id: UUID | None = None, asker: str | None = None, acc: UUID = Depends(account),
                        a: Api = Depends(api)):
    lang = await _lang(a.deps.pool, acc)
    return [r.public(lang) for r in await T.list_all(a.deps.pool, acc, companion=companion_id, asker=asker)]


@router.get("/tarot/readings/{rid}")
async def one(rid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    return (await _own(a, acc, rid)).public(await _lang(a.deps.pool, acc))


@router.post("/tarot/readings/{rid}/followup", status_code=201)
async def followup(rid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{deck_id, pick, question, mode}：还是原来那位来解。"""
    await _own(a, acc, rid)
    lang = await _lang(a.deps.pool, acc)
    try:
        r, i = await T.add_followup(a.deps.pool, acc, rid, deck_id=int(body.get("deck_id") or 0), pick=body.get("pick"),
                                    question=str(body.get("question") or ""), mode=str(body.get("mode") or ""),
                                    now=a.deps.now(), lang=lang)
    except T.TarotError as e:
        raise HTTPException(400, str(e)) from e
    _kick(a, acc, rid, i)
    return r.public(lang)


@router.post("/tarot/readings/{rid}/retry")
async def retry(rid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    """解失败了（三次不成）：再来一次。"""
    await _own(a, acc, rid)
    got = await T.retry(a.deps.pool, acc, rid)
    if got is None:
        raise HTTPException(409, "这一局没有解失败的")
    r, idx = got
    if r.status == "pending":
        _kick(a, acc, rid)
    for i in idx:
        _kick(a, acc, rid, i)
    return r.public(await _lang(a.deps.pool, acc))


@router.delete("/tarot/readings/{rid}", status_code=204)
async def delete(rid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await T.delete(a.deps.pool, acc, rid):
        raise HTTPException(404, "没有这一局")
    return Response(status_code=204)
