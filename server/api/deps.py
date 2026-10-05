"""认人、核对归属（2026-09-27，第 4 步）。

每个请求带 `Authorization: Bearer <登录凭证>`，认不出就 401。
联系人、窗口的 id 不属于这个账号一律 404（不说 403，免得被人拿 id 试探有没有这个东西）。"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from uuid import UUID

from fastapi import Depends, HTTPException, Request

from brain import accounts, auth
from brain.scope import Scope
from brain.turn import Deps

from .rooms import Rooms


@dataclass
class ApiConfig:
    secret: str                       # 验证码、登录凭证、设备标记的哈希秘钥（NEWAPP_SECRET）
    box: auth.KeyBox                  # 钥匙串的主密钥（NEWAPP_MASTER_KEY）
    wait_scale: float = 1.0           # 等候区的秒数乘这个（测试里调小）
    send_code: object = None          # send_code(email, code)：发验证码邮件；None = 打到日志里（本机）
    patrol: bool = False              # 起巡逻的循环（正式服务器开；测试里关着，直接调 wake_once）
    files_dir: Path = Path(__file__).resolve().parent.parent / ".local" / "files"   # 附件存哪（NEWAPP_FILES_DIR）
    apns: object = None               # push.apns.ApnsConfig：配了才真发推送（NEWAPP_APNS_*），没配只排队
    push_relay: str | None = None     # 推送中转（Mele Host，10-04）：relay: 开头的设备加密后交给它（NEWAPP_PUSH_RELAY）
    host_mode: bool = False           # Mele Host 单人模式（10-04）：不注册、不发验证码，扫配对码绑定唯一主人


@dataclass
class Api:
    deps: Deps
    cfg: ApiConfig
    rooms: Rooms = field(default_factory=Rooms)
    app_state: dict = field(default_factory=dict)      # 进程里的小东西（配对连错几次），重启清零


def api(request: Request) -> Api:
    return request.app.state.api


def bearer(request: Request) -> str:
    h = request.headers.get("authorization", "")
    return h[7:].strip() if h.lower().startswith("bearer ") else ""


async def account(request: Request, a: Api = Depends(api)) -> UUID:
    token = bearer(request)
    acc = await auth.account_for(a.deps.pool, token, secret=a.cfg.secret, now=a.deps.now()) if token else None
    if acc is None:
        raise HTTPException(401, "请先登录")
    return acc


async def own_companion(a: Api, acc: UUID, companion_id: UUID) -> UUID:
    if companion_id not in await accounts.list_companions(a.deps.pool, acc):
        raise HTTPException(404, "没有这个联系人")
    return companion_id


async def own_conversation(a: Api, acc: UUID, conversation_id: UUID) -> Scope:
    try:
        return await accounts.scope_for(a.deps.pool, acc, conversation_id)
    except PermissionError:
        raise HTTPException(404, "没有这个窗口") from None
