"""标记表情（2026-09-27，iOS 第一块；照之前自用的 App〔她点了表情〕）：TA 长按它的一句点个 ❤️。
只点表情不叫它回话；下一轮易变区多一行告诉它，说过就不再说。它给 TA 点表情先不做。"""
from __future__ import annotations

from uuid import UUID

SNIP = 20
LINE = {"zh": "〔TA 给你那句「{t}」点了 {e}〕", "en": "〔They reacted {e} to your line \"{t}\"〕"}


async def set_reaction(pool, conversation: UUID, message_id: int, emoji: str | None) -> None:
    if emoji:
        await pool.execute(
            """INSERT INTO reactions (message_id, conversation_id, emoji) VALUES ($1, $2, $3)
               ON CONFLICT (message_id) DO UPDATE SET emoji = $3, created_at = now(), told = FALSE""",
            message_id, conversation, emoji)
    else:
        await pool.execute("DELETE FROM reactions WHERE message_id = $1", message_id)


async def for_messages(pool, ids: list[int]) -> dict[int, str]:
    if not ids:
        return {}
    rows = await pool.fetch("SELECT message_id, emoji FROM reactions WHERE message_id = ANY($1::bigint[])", ids)
    return {r["message_id"]: r["emoji"] for r in rows}


async def pending_lines(pool, conversation: UUID, lang: str) -> list[str]:
    """还没告诉它的表情，一条一行；取了就标 told。"""
    rows = await pool.fetch(
        """UPDATE reactions r SET told = TRUE FROM chat_messages m
           WHERE r.message_id = m.id AND r.conversation_id = $1 AND NOT r.told
           RETURNING r.emoji, m.text, r.created_at""", conversation)
    out = []
    for r in sorted(rows, key=lambda r: r["created_at"]):
        t = " ".join(r["text"].split())
        out.append(LINE[lang].format(t=t if len(t) <= SNIP else t[:SNIP] + "…", e=r["emoji"]))
    return out
