"""一轮对话在谁的名下（2026-09-27，账号 + 联系人 + 接口那块）。

表里的 `user_id` 栏现在当「主人」用，主人分三层，每样东西归哪一层是Tilia定的：
- 账号 account：人物卡（每个联系人都认识 TA 身边的人）、钥匙串、用量。
- 联系人 companion：记忆、「关于 TA」、核心、便利贴、人设、设置——每个 AI 各记各的。
- 窗口 conversation：聊天记录、账本、状态、每轮日志——开新窗口就是一个新的。
记忆服务不用改：它只认「主人是谁」，照样隔得严严实实。
测试里三层用同一个 id（Scope.single），旧测试照旧能过。"""
from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID


@dataclass(frozen=True)
class Scope:
    account: UUID
    companion: UUID
    conversation: UUID
    incognito: bool = False      # 无痕：不知道对面是 TA、不存档、不记东西（第 2 步接上）

    @classmethod
    def single(cls, uid: UUID) -> "Scope":
        return cls(uid, uid, uid)

    @classmethod
    def of(cls, x: "Scope | UUID") -> "Scope":
        return x if isinstance(x, Scope) else cls.single(x)
