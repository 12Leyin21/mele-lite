"""钱包记账的接口（10-02）：一个月的账、记 / 改 / 删一笔、设置（币种、预算、自己加的分类）。"""
from __future__ import annotations

from datetime import date
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import accounts, archive
from brain import wallet as W
from brain.settings import Settings

from .deps import Api, account, api

router = APIRouter()


async def _today(a: Api, acc: UUID) -> date:
    comps = await accounts.list_companions(a.deps.pool, acc)
    tz = Settings.from_dict(await archive.get_settings(a.deps.pool, comps[0])).tz if comps else "UTC"
    return a.deps.now().astimezone(ZoneInfo(tz)).date()


def _day(v) -> date | None:
    if not v:
        return None
    try:
        return date.fromisoformat(str(v))
    except ValueError:
        raise HTTPException(400, "日期要写成 YYYY-MM-DD") from None


@router.get("/wallet")
async def month(month: str = "", acc: UUID = Depends(account), a: Api = Depends(api)):
    """month = YYYY-MM（不填 = 这个月）"""
    try:
        m = date.fromisoformat(month + "-01") if month else await _today(a, acc)
    except ValueError:
        raise HTTPException(400, "月份要写成 YYYY-MM") from None
    return await W.month(a.deps.pool, acc, m)


@router.post("/wallet", status_code=201)
async def add(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{amount: "6.5", category（标签，写新的会自己存进标签栏）, kind?: out / in, note?, day?}"""
    try:
        return await W.add(a.deps.pool, acc, amount=body.get("amount"), category=str(body.get("category") or ""),
                           kind=str(body.get("kind") or "out"),
                           note=str(body.get("note") or ""), day=_day(body.get("day")) or await _today(a, acc),
                           now=a.deps.now())
    except W.WalletError as e:
        raise HTTPException(400, str(e)) from e


@router.get("/wallet/receipt")
async def receipt(day: str = "", acc: UUID = Depends(account), a: Api = Depends(api)):
    """一天的小票（不填 = 今天）"""
    return await W.receipt(a.deps.pool, acc, _day(day) or await _today(a, acc))


@router.patch("/wallet/{eid}")
async def update(eid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        e = await W.update(a.deps.pool, acc, eid, amount=body.get("amount"), category=body.get("category"),
                           note=body.get("note"), day=_day(body.get("day")))
    except W.WalletError as err:
        raise HTTPException(400, str(err)) from err
    if e is None:
        raise HTTPException(404, "没有这一笔")
    return e


@router.delete("/wallet/{eid}", status_code=204)
async def delete(eid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await W.delete(a.deps.pool, acc, eid):
        raise HTTPException(404, "没有这一笔")
    return Response(status_code=204)


@router.put("/wallet/settings")
async def save_settings(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{currency?, budget?（一个月，「0」= 不设）, custom?: {out: [...], in: [...]}（自己写过的标签）}"""
    try:
        return await W.save_settings(a.deps.pool, acc, currency=body.get("currency"), budget=body.get("budget"),
                                     custom=body.get("custom"))
    except W.WalletError as e:
        raise HTTPException(400, str(e)) from e
