"""倒回、无痕（2026-09-27 Tilia定）。

倒回：长按一条消息 →「倒回到这里」。这条之后的全删掉；那几轮里它记下或改过的东西一起撤回。
只能倒回到还没卷进账本的那段原文里。倒回会让这个窗口的缓存作废一次。
无痕：一个临时窗口（conversations.incognito）。开着的时候它不知道对面是 TA、什么都不记；关掉就整个删干净。"""
from __future__ import annotations

from uuid import UUID

from . import accounts, archive, attachments, edits
from .scope import Scope


async def _cut(pool, embedder, scope: Scope, from_msg: int, undo_from: int) -> None:
    """从 from_msg 这条起（含）全删；从 undo_from 那一轮起写过的东西全撤。"""
    await edits.undo(pool, embedder, scope.conversation, undo_from)
    await attachments.wipe_from(pool, scope.conversation, from_msg)
    await archive.delete_messages_after(pool, scope.conversation, from_msg - 1)
    state = await archive.get_state(pool, scope.conversation)
    state["last_tools"] = []
    await archive.save_state(pool, scope.conversation, state)


async def _find(pool, scope: Scope, message_id: int, role: str):
    msgs = await archive.unrolled(pool, scope.conversation)
    i = next((i for i, m in enumerate(msgs) if m.id == message_id), None)
    if i is None:
        raise ValueError("只能倒回到还没卷进账本的消息")
    if msgs[i].role != role:
        raise ValueError("这条不能倒回")
    return msgs, i


async def rewind_to_user(pool, embedder, scope: Scope, message_id: int) -> str:
    """点用户的一句（Tilia 09-27 定）：回到这句还没发出去的时候——这句和之后的全撤，把这句的原文还给输入栏重新编辑。"""
    msgs, i = await _find(pool, scope, message_id, "user")
    await _cut(pool, embedder, scope, message_id, message_id)
    return msgs[i].text


async def undo_reply(pool, embedder, scope: Scope, message_id: int) -> None:
    """点它一轮回复的最后一条：这一轮的回复和这一轮它写过的东西全撤，接着让它重新回（调用方 run_turn(resend=True)）。"""
    msgs, i = await _find(pool, scope, message_id, "assistant")
    asked = next((m for m in reversed(msgs[:i]) if m.role in archive.USER_SIDE), None)
    if asked is not None and asked.role == "wake":
        raise ValueError("它自己醒来说的话不能倒回")
    await _cut(pool, embedder, scope, message_id, asked.id if asked else message_id)


async def start_incognito(pool, account: UUID, companion: UUID) -> Scope:
    conv = await accounts.new_conversation(pool, account, companion, incognito=True)
    return Scope(account, companion, conv, incognito=True)


async def end_incognito(pool, scope: Scope) -> None:
    """关掉无痕：这段整段丢掉——聊天、账本、状态、每轮日志、窗口本身。用量照记在账号上（钱是真花了）。"""
    ok = await pool.fetchval("SELECT incognito FROM conversations WHERE id = $1 AND account_id = $2",
                             scope.conversation, scope.account)
    if not ok:
        raise PermissionError("这不是一个无痕窗口")
    await attachments.wipe(pool, "conversation_id", scope.conversation)
    async with pool.acquire() as conn:
        async with conn.transaction():
            for table in ("chat_messages", "ledger_days", "user_state", "turn_logs"):
                await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", scope.conversation)
            await conn.execute("DELETE FROM memory_edits WHERE conversation_id = $1", scope.conversation)
            await conn.execute("DELETE FROM conversations WHERE id = $1", scope.conversation)
