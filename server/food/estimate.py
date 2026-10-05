"""饮食的后台估算（09-29，Tilia选 A：跟之前自用的 App一样，一提交就开始估，不等 TA 去聊天）。

只有字：用账号主联系人的钥匙 / 模型。带照片：所有照片一起给会看图的模型（照 brain/vision 的挑法：TA 自己会看图的钥匙 → 我们的）。
估好写回、status estimated、told=false（下一轮〔饮食〕告诉它）；解析不了 = failed；没钥匙 / 额度用完 = 留着 pending 并写明为什么。
花的钱记用量，试用的扣额度。"""
from __future__ import annotations

import asyncio
import base64
import logging
from pathlib import Path
from uuid import UUID

from brain import accounts, archive
from brain.auth import TrialOver, charge_trial
from brain.context import user_tag
from brain.scope import Scope
from brain.settings import Settings
from brain.vision import _describer
from llm.catalog import cost
from llm.errors import LLMError
from llm.router import call
from llm.types import Block, ChatRequest, ImagePart, Msg

from . import logic as L
from . import store as S

log = logging.getLogger(__name__)
_TASKS: set[asyncio.Task] = set()
NOTE = {"zh": {"trial": "免费额度今天用完了，明天会自动估；也可以现在手填",
               "failed": "没估出来，可以手填", "no_eye": "看不了照片，只按文字估的"},
        "en": {"trial": "Today's free quota is used up — it'll be estimated tomorrow, or fill it in now",
               "failed": "Couldn't estimate this one — you can fill it in", "no_eye": "Couldn't look at the photos; estimated from the text"}}


def schedule(deps, account: UUID, entry_id: int) -> None:
    """丢进后台，接口立刻返回。"""
    t = asyncio.create_task(_safe(deps, account, entry_id))
    _TASKS.add(t)
    t.add_done_callback(_TASKS.discard)


async def drain() -> None:
    """测试用：等后台估完。"""
    while _TASKS:
        await asyncio.gather(*list(_TASKS), return_exceptions=True)


async def _safe(deps, account, entry_id) -> None:
    try:
        await run(deps, account, entry_id)
    except Exception:                                        # noqa: BLE001 —— 估不出来不能把服务器带崩
        log.exception("food estimate %s", entry_id)


async def _scope(pool, account: UUID) -> tuple[Scope | None, Settings]:
    comps = await accounts.list_companions(pool, account)
    if not comps:
        return None, Settings()
    conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND NOT incognito "
                               "ORDER BY last_at DESC LIMIT 1", comps[0])
    return Scope(account, comps[0], conv or comps[0]), Settings.from_dict(await archive.get_settings(pool, comps[0]))


async def _write(pool, account, entry_id, *, status: str, note: str, got: dict | None = None) -> None:
    got = got or {}
    await pool.execute(
        """UPDATE food_entries SET kcal = $3, protein = $4, carbs = $5, fat = $6,
           portion = CASE WHEN $7 <> '' THEN $7 ELSE portion END, status = $8, note = $9, updated_at = now(),
           told = CASE WHEN $8 = 'estimated' THEN FALSE ELSE told END,
           text = CASE WHEN text = $10 AND $11 <> '' THEN $11 ELSE text END      -- 只拍了照片的：换成模型起的名
           WHERE id = $1 AND account_id = $2 AND status IN ('pending', 'failed')""",   # TA 这期间手填了就不盖
        entry_id, account, got.get("kcal"), got.get("protein"), got.get("carbs"), got.get("fat"),
        got.get("portion") or "", status, note, L.PHOTO_ONLY, got.get("name") or "")


PAST = 6          # 带几条 TA 改过的估算当参考


async def corrections(pool, account: UUID, limit: int = PAST) -> list:
    """TA 最近手改过的估算（09-30 Tilia：甜筒估 300、实际 190）。差不到一成的、运动的不算。"""
    return await pool.fetch(
        """SELECT text, detail, est_kcal, est_portion, kcal FROM food_entries
           WHERE account_id = $1 AND status = 'manual' AND est_kcal IS NOT NULL AND kcal IS NOT NULL AND meal <> $2
             AND abs(kcal - est_kcal) >= 0.1 * est_kcal
           ORDER BY updated_at DESC LIMIT $3""", account, L.EXERCISE, limit)


async def run(deps, account: UUID, entry_id: int) -> None:
    from brain.turn import get_adapter, resolve_route           # 大脑那边的，用到时才引
    pool = deps.pool
    e = await S.get(pool, account, entry_id)
    if e is None or e["status"] not in ("pending", "failed"):
        return
    scope, s = await _scope(pool, account)
    lang = s.lang
    if scope is None:
        return
    try:
        route = await resolve_route(deps.keys, scope)
    except TrialOver:
        await _write(pool, account, entry_id, status="pending", note=NOTE[lang]["trial"])
        return
    photos = [r for r in await pool.fetch(
        "SELECT a.mime, a.path FROM food_photos p JOIN attachments a ON a.id = p.attachment_id "
        "WHERE p.entry_id = $1 ORDER BY p.pos", entry_id)]
    use, note_extra = route, ""
    if photos:
        eye, _src = await _describer(deps, scope, route)
        if eye is None:
            photos, note_extra = [], NOTE[lang]["no_eye"]
        else:
            use = eye
    where = str((await S.settings(pool, account)).get("country") or "").upper() or (s.tz if s.tz != "UTC" else "")
    images = tuple(ImagePart(p["mime"], base64.b64encode(Path(p["path"]).read_bytes()).decode()) for p in photos)
    req = ChatRequest(model=use.chat_model, system=[Block(L.ESTIMATE_SYSTEM[lang])],
                      messages=[Msg("user", L.estimate_prompt(e, photos=len(images), lang=lang, where=where,
                                                             past=await corrections(pool, account)), images=images)],
                      max_tokens=400, thinking=False, user_tag=user_tag(account))
    day = await S.today(pool, account, deps.now())
    try:
        reply = await call(get_adapter(deps, use), req)
    except LLMError:
        await _write(pool, account, entry_id, status="failed", note=NOTE[lang]["failed"])
        return
    spent = cost(reply.usage, use.chat_model)
    await archive.add_usage(pool, account, day, use.chat_model, reply.usage, spent)
    if route.trial and use is route and spent:
        await charge_trial(pool, account, round(spent * 1_000_000))
    got = L.parse_estimate(reply.text)
    if got is None:
        await _write(pool, account, entry_id, status="failed", note=NOTE[lang]["failed"])
        return
    await _write(pool, account, entry_id, status="estimated",
                 note="；".join(x for x in (got.get("note") or "", note_extra) if x), got=got)
