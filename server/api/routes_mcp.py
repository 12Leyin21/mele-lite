"""用户自己的 MCP 服务（10-05，Host 才有；brain/mcp.py）。路由跟 Lite 本机（ios/Lite/LocalMCP.swift）同一套，App 两边共用界面：
GET / POST /mcp/servers，PATCH / DELETE /mcp/servers/{id}，POST /mcp/servers/{id}/test。
钥匙只进不出（列表里只说 has_key）。Host 是单人服务器，地址由主人自己填，所以不拦内网地址。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException

from brain import mcp

from .deps import Api, account, api

router = APIRouter()


def _host(a: Api) -> None:
    if not a.cfg.host_mode:
        raise HTTPException(404, "这不是 Mele Host")


@router.get("/mcp/servers")
async def list_servers(acc=Depends(account), a: Api = Depends(api)):
    _host(a)
    keys = await mcp.has_keys(a.deps.pool, acc)
    return [s.public(keys.get(s.id, False)) for s in await mcp.servers(a.deps.pool, a.cfg.box, acc)]


@router.post("/mcp/servers", status_code=201)
async def add_server(body: dict = Body(...), acc=Depends(account), a: Api = Depends(api)):
    _host(a)
    name, url = str(body.get("name") or "").strip(), str(body.get("url") or "").strip()
    if not name:
        raise HTTPException(400, "起个名字")
    if not mcp.valid_url(url):
        raise HTTPException(400, "地址要以 https:// 开头")
    try:
        s = await mcp.add(a.deps.pool, a.cfg.box, acc, name, url, str(body.get("token") or "").strip(), now=a.deps.now())
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    return {"id": str(s.id), "name": s.name, "url": s.url, "slug": s.slug}


@router.patch("/mcp/servers/{sid}")
async def update_server(sid: UUID, body: dict = Body(...), acc=Depends(account), a: Api = Depends(api)):
    _host(a)
    if body.get("url") and not mcp.valid_url(str(body["url"]).strip()):
        raise HTTPException(400, "地址要以 https:// 开头")
    if not await mcp.update(a.deps.pool, a.cfg.box, acc, sid, body):
        raise HTTPException(404, "没有这个服务")
    s = next(x for x in await mcp.servers(a.deps.pool, a.cfg.box, acc) if x.id == sid)
    return {"id": str(s.id), "name": s.name, "url": s.url, "slug": s.slug}


@router.delete("/mcp/servers/{sid}")
async def delete_server(sid: UUID, acc=Depends(account), a: Api = Depends(api)):
    _host(a)
    if not await mcp.delete(a.deps.pool, acc, sid):
        raise HTTPException(404, "没有这个服务")
    return {"ok": True}


@router.post("/mcp/servers/{sid}/test")
async def test_server(sid: UUID, acc=Depends(account), a: Api = Depends(api)):
    _host(a)
    s = next((x for x in await mcp.servers(a.deps.pool, a.cfg.box, acc) if x.id == sid), None)
    if s is None:
        raise HTTPException(404, "没有这个服务")
    mcp.forget(sid)
    try:
        t = await mcp.tools(s, fresh=True)
    except mcp.MCPError as e:
        return {"ok": False, "detail": "钥匙不对" if e.kind == "unauthorized" else "连不上，看看地址对不对、服务开着没"}
    return {"ok": True, "tools": [x["name"] for x in t], "memory": mcp.is_memory(t)}
