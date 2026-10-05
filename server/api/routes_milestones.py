"""里程碑（10-05）：Record 的大事记读这个。立是它在聊天里用 milestone 工具。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends

from brain import milestones as MS

from .deps import Api, account, api

router = APIRouter()


@router.get("/milestones")
async def list_milestones(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await MS.list_all(a.deps.pool, acc)
