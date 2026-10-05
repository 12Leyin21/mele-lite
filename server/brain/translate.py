"""思考链翻译（10-01 Tilia）：Claude 用英文想（中文想得太短太干），App 的思考链上有个「翻译」按钮——
用这个联系人那把钥匙的便宜模型（写账本那个）翻成中文，按消息存一份，再点直接给。"""
from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from llm.catalog import cost
from llm.router import call
from llm.types import Block, ChatRequest, Msg

from . import archive
from .scope import Scope
from .settings import Settings

PROMPT = ("把下面这段内心独白翻成自然的中文。保持第一人称、原来的语气、停顿和转弯，口语一点；"
          "不总结、不删、不加东西，人名和专有名词照原文。只给译文。\n\n{text}")


async def thinking_zh(deps, scope: Scope, message_id: int, thinking: str, now: datetime) -> str:
    pool = deps.pool
    got = await pool.fetchval("SELECT text FROM thinking_translations WHERE message_id = $1 AND lang = 'zh'", message_id)
    if got:
        return got
    from .turn import get_adapter, resolve_route
    route = await resolve_route(deps.keys, scope)
    model = route.ledger_model or route.chat_model
    reply = await call(get_adapter(deps, route), ChatRequest(
        model=model, system=[Block("You translate faithfully into natural Chinese.")],
        messages=[Msg("user", PROMPT.format(text=thinking))], max_tokens=4000))
    text = reply.text.strip()
    tz = Settings.from_dict(await archive.get_settings(pool, scope.companion)).tz
    await archive.add_usage(pool, scope.account, now.astimezone(ZoneInfo(tz)).date(), model, reply.usage,
                            cost(reply.usage, model))
    if text:
        await pool.execute("""INSERT INTO thinking_translations (message_id, lang, text) VALUES ($1, 'zh', $2)
                              ON CONFLICT (message_id, lang) DO UPDATE SET text = EXCLUDED.text""", message_id, text)
    return text
