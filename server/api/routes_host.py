"""Mele Host（10-04）：自己部署的单人服务器。
/version 给 App 判断连的是不是 Host、接口版本对不对得上；/host/pair 用配对码换登录凭证；
/me/import 收 Lite 手机里搬来的东西（第三步）。"""
from __future__ import annotations

from datetime import timedelta

from fastapi import APIRouter, Body, Depends, HTTPException

from brain import auth, host, host_import

from .deps import Api, account, api

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
        return await host_import.run(a.deps.pool, a.cfg.box, acc, body, files_dir=a.cfg.files_dir, now=a.deps.now())
    except host_import.ImportError_ as e:
        raise HTTPException(400, str(e)) from e
