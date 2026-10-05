"""用户自己的 MCP 服务（10-05，Host 才有；Lite 本机那份是 ios/Lite/LocalMCP.swift，路由同一套）。

Me 里填名字、地址、钥匙（钥匙用 Host 的主密钥加密存），TA 设定里勾能用哪几个（settings.mcp_servers）。
每一轮聊天前把勾上的服务的工具列出来（缓存 10 分钟），名字改成 <slug>_<原名> 交给模型；它调了就转给那个服务。
记忆库型的服务在 Host 上也只当普通工具用：Host 自己有记忆，不另外 wake / recall。
连法是 MCP Streamable HTTP：每次 POST 一条 JSON-RPC，回来的可能是 JSON，也可能是 SSE（只取 id 对得上的那条）。"""
from __future__ import annotations

import json
import logging
import re
import time
from dataclasses import dataclass, field
from datetime import datetime
from uuid import UUID, uuid4

import httpx

from llm.types import ToolSpec

log = logging.getLogger(__name__)

PROTOCOL = "2025-06-18"
CACHE_SECONDS = 600
MAX_SERVERS = 20
MAX_RESULT = 8000
_clients: dict[UUID, "Client"] = {}
_tools: dict[UUID, tuple[float, list[dict]]] = {}
_health: dict[UUID, str] = {}
TRANSPORT: httpx.AsyncBaseTransport | None = None     # 测试里换成假的 MCP 服务


class MCPError(Exception):
    def __init__(self, kind: str, detail: str = ""):
        super().__init__(f"{kind}: {detail}")
        self.kind, self.detail = kind, detail          # unauthorized / http / rpc / bad / timeout / offline


class Client:
    def __init__(self, url: str, token: str | None, *, http: httpx.AsyncClient | None = None):
        self.url, self.token = url, token or None
        self.http = http
        self.session_id: str | None = None
        self.ready = False
        self.next_id = 1

    async def list_tools(self) -> list[dict]:
        out, cursor = [], None
        while True:
            r = await self._request("tools/list", {"cursor": cursor} if cursor else {}, timeout=10)
            for t in r.get("tools") or []:
                if isinstance(t, dict) and t.get("name"):
                    out.append({"name": str(t["name"]), "description": str(t.get("description") or ""),
                                "schema": t.get("inputSchema") or {"type": "object", "properties": {}}})
            cursor = r.get("nextCursor")
            if not cursor:
                return out

    async def call(self, name: str, args: dict, timeout: float = 20) -> tuple[str, bool]:
        r = await self._request("tools/call", {"name": name, "arguments": args or {}}, timeout=timeout)
        text = "\n".join(c.get("text", "") for c in r.get("content") or [] if isinstance(c, dict) and c.get("type") == "text")
        if not text and isinstance(r.get("structuredContent"), dict):
            text = json.dumps(r["structuredContent"], ensure_ascii=False)
        return text, bool(r.get("isError"))

    async def _request(self, method: str, params: dict, timeout: float) -> dict:
        if not self.ready:
            await self._handshake()
        try:
            return await self._rpc(method, params, timeout)
        except MCPError as e:
            if e.kind == "http" and e.detail == "404" and self.session_id:     # 会话过期（对面重启过）：重新握手，只重试一次
                self.ready, self.session_id = False, None
                await self._handshake()
                return await self._rpc(method, params, timeout)
            raise

    async def _handshake(self) -> None:
        await self._rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                       "clientInfo": {"name": "Mele Host", "version": "1"}}, 10)
        await self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, 10, expect=False)
        self.ready = True

    async def _rpc(self, method: str, params: dict, timeout: float) -> dict:
        rid = self.next_id
        self.next_id += 1
        msgs = await self._post({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}, timeout, expect=True)
        msg = next((m for m in msgs if m.get("id") == rid), None)
        if msg is None:
            raise MCPError("bad", "没有对上号的回复")
        if isinstance(msg.get("error"), dict):
            raise MCPError("rpc", str(msg["error"].get("message") or ""))
        if not isinstance(msg.get("result"), dict):
            raise MCPError("bad", "回复里没有 result")
        return msg["result"]

    async def _post(self, body: dict, timeout: float, *, expect: bool) -> list[dict]:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": PROTOCOL}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        own = self.http is None
        http = self.http or (httpx.AsyncClient(transport=TRANSPORT) if TRANSPORT else httpx.AsyncClient())
        try:
            resp = await http.post(self.url, json=body, headers=headers, timeout=timeout)
        except httpx.TimeoutException as e:
            raise MCPError("timeout") from e
        except httpx.HTTPError as e:
            raise MCPError("offline", str(e)) from e
        finally:
            if own:
                await http.aclose()
        if resp.status_code in (401, 403):
            raise MCPError("unauthorized")
        if not 200 <= resp.status_code < 300:
            raise MCPError("http", str(resp.status_code))
        if sid := resp.headers.get("mcp-session-id"):
            self.session_id = sid
        if not expect:
            return []
        if "text/event-stream" in resp.headers.get("content-type", ""):
            out = []
            for block in resp.text.replace("\r\n", "\n").split("\n\n"):
                payload = "\n".join(line[5:].strip() for line in block.split("\n") if line.startswith("data:"))
                try:
                    obj = json.loads(payload)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
            return out
        try:
            obj = resp.json()
        except ValueError as e:
            raise MCPError("bad", "回复不是 JSON") from e
        if isinstance(obj, dict):
            return [obj]
        if isinstance(obj, list):
            return [o for o in obj if isinstance(o, dict)]
        raise MCPError("bad", "回复不是 JSON-RPC")


# ── 名字（跟 MeleLiteCore/MCPToolNames.swift 一样）──

def slug(name: str, fallback: int) -> str:
    out = ""
    for ch in name.lower():
        if "a" <= ch <= "z" or "0" <= ch <= "9":
            out += ch
        elif out and not out.endswith("_"):
            out += "_"
    out = out.strip("_")
    return out[:20] if out else f"mcp{fallback}"


def exposed(slug_: str, tool: str) -> str:
    return f"{slug_}_{re.sub(r'[^A-Za-z0-9_-]', '_', tool)}"[:64]


def is_memory(tools: list[dict]) -> bool:
    return {"wake", "recall", "person_upsert"} <= {t["name"] for t in tools}


# ── 存（钥匙用主密钥加密）──

@dataclass
class Server:
    id: UUID
    name: str
    url: str
    slug: str
    token: str | None = None

    def public(self, has_key: bool) -> dict:
        return {"id": str(self.id), "name": self.name, "url": self.url, "slug": self.slug, "has_key": has_key,
                "status": _health.get(self.id), "memory": is_memory(_tools[self.id][1]) if self.id in _tools else False}


def valid_url(url: str) -> bool:
    return bool(re.match(r"^https?://[^\s/]+", url or ""))


async def servers(pool, box, acc: UUID) -> list[Server]:
    rows = await pool.fetch("SELECT id, name, url, slug, secret FROM mcp_servers WHERE account_id = $1 ORDER BY created_at", acc)
    return [Server(r["id"], r["name"], r["url"], r["slug"], box.unlock(r["secret"]) if r["secret"] and box else None)
            for r in rows]


async def has_keys(pool, acc: UUID) -> dict[UUID, bool]:
    rows = await pool.fetch("SELECT id, secret IS NOT NULL AS k FROM mcp_servers WHERE account_id = $1", acc)
    return {r["id"]: r["k"] for r in rows}


async def add(pool, box, acc: UUID, name: str, url: str, token: str, *, now: datetime) -> Server:
    taken = {r["slug"] for r in await pool.fetch("SELECT slug FROM mcp_servers WHERE account_id = $1", acc)}
    if len(taken) >= MAX_SERVERS:
        raise ValueError(f"最多接 {MAX_SERVERS} 个")
    s = slug(name, len(taken) + 1)
    if s in taken:
        s = f"{s}{len(taken) + 1}"
    sid = uuid4()
    await pool.execute("INSERT INTO mcp_servers (id, account_id, name, url, slug, secret, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7)",
                       sid, acc, name, url, s, box.lock(token) if token else None, now)
    return Server(sid, name, url, s, token or None)


async def update(pool, box, acc: UUID, sid: UUID, body: dict) -> bool:
    row = await pool.fetchrow("SELECT id FROM mcp_servers WHERE account_id = $1 AND id = $2", acc, sid)
    if row is None:
        return False
    for k in ("name", "url"):
        v = str(body.get(k) or "").strip()
        if v:
            await pool.execute(f"UPDATE mcp_servers SET {k} = $2 WHERE id = $1", sid, v)
    if "token" in body:
        t = str(body.get("token") or "").strip()
        await pool.execute("UPDATE mcp_servers SET secret = $2 WHERE id = $1", sid, box.lock(t) if t else None)
    forget(sid)
    return True


async def delete(pool, acc: UUID, sid: UUID) -> bool:
    from . import accounts, archive
    gone = await pool.fetchval("DELETE FROM mcp_servers WHERE account_id = $1 AND id = $2 RETURNING id", acc, sid)
    if gone is None:
        return False
    forget(sid)
    for cid in await accounts.list_companions(pool, acc):           # TA 设定里的勾一起清掉
        s = await archive.get_settings(pool, cid)
        if str(sid) in (s.get("mcp_servers") or []):
            s["mcp_servers"] = [x for x in s["mcp_servers"] if x != str(sid)]
            await archive.save_settings(pool, cid, s)
    return True


def forget(sid: UUID) -> None:
    _clients.pop(sid, None)
    _tools.pop(sid, None)
    _health.pop(sid, None)


def client(sv: Server) -> Client:
    c = _clients.get(sv.id)
    if c is None or c.url != sv.url or c.token != (sv.token or None):
        c = _clients[sv.id] = Client(sv.url, sv.token)
    return c


async def tools(sv: Server, *, fresh: bool = False) -> list[dict]:
    hit = _tools.get(sv.id)
    if not fresh and hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    try:
        got = await client(sv).list_tools()
    except MCPError as e:
        _health[sv.id] = "unauthorized" if e.kind == "unauthorized" else "offline"
        raise
    _tools[sv.id] = (time.monotonic(), got)
    _health.pop(sv.id, None)
    return got


# ── 一轮聊天里 ──

@dataclass
class Toolbox:
    specs: list[ToolSpec] = field(default_factory=list)
    route: dict[str, tuple[Server, str]] = field(default_factory=dict)


async def toolbox(pool, box, acc: UUID, enabled: list[str]) -> Toolbox:
    out = Toolbox()
    on = {str(x) for x in enabled or []}
    if not on:
        return out
    for sv in await servers(pool, box, acc):
        if str(sv.id) not in on:
            continue
        try:
            ts = await tools(sv)
        except MCPError:
            continue                                   # 连不上的这一轮先不给，不挡聊天
        for t in ts:
            name = exposed(sv.slug, t["name"])
            out.specs.append(ToolSpec(name=name, description=f"（来自 {sv.name}）{t['description']}", params=t["schema"]))
            out.route[name] = (sv, t["name"])
    return out


async def run(ctx, name: str, args: dict) -> str:
    from .tools import Card
    sv, tool = ctx.mcp[name]
    try:
        text, err = await client(sv).call(tool, args)
    except MCPError as e:
        _health[sv.id] = "unauthorized" if e.kind == "unauthorized" else "offline"
        return f"没成：{sv.name} 连不上" if ctx.lang == "zh" else f"Failed: can't reach {sv.name}"
    if err:
        return f"没成：{text[:MAX_RESULT]}"
    ctx.cards.append(Card("tool", f"{'用了' if ctx.lang == 'zh' else 'Used'} {sv.name}：{tool}"))
    return text[:MAX_RESULT] or ("好了" if ctx.lang == "zh" else "Done")
