"""表情包库（10-01 Tilia，设计 specs/2026-10-01-stickers-design.md）。

一个账号一个库，所有联系人共用；某几张可以标「只给谁」（only_for 空 = 都能用）。最多 300 张。
- 收：上传的图（相册多选）或聊天里的一个附件；同一张（按原始字节的指纹）不重复收。原样存，不转 JPEG，gif 能动。
- 描述：会看图的模型写一次（先查指纹，看过的直接用），TA 能改；名字 + 描述算向量，它按意思找。
- 它发：工具 sticker 搜到几张、挑一张发（挂一张 kind=sticker 的卡）；TA 发：面板点一张变成这个窗口的附件。"""
from __future__ import annotations

import hashlib
import io
import logging
import shutil
import uuid
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from uuid import UUID

from PIL import Image

from memory.embed import embed_one

log = logging.getLogger(__name__)

MAX_STICKERS = 300
MAX_BYTES = 2 * 1024 * 1024
MAX_GIF_BYTES = 5 * 1024 * 1024
NAME_MAX, CAPTION_MAX = 20, 300
SEARCH_LIMIT = 5
FORMATS = {"PNG": ("image/png", ".png"), "JPEG": ("image/jpeg", ".jpg"), "GIF": ("image/gif", ".gif"),
           "WEBP": ("image/webp", ".webp")}

PROMPT = {"zh": "这是一张聊天用的表情包。用一两句话写：画面上是什么（有字就照抄），它表达的情绪或意思、适合在什么时候发。不评价。",
          "en": "This is a chat sticker. In one or two sentences: what's in it (copy any text exactly), the feeling or meaning "
                "it conveys, and when it fits to send. No judging."}


class StickerError(ValueError):
    """给用户看的人话。"""


@dataclass
class Sticker:
    id: int
    account_id: UUID
    sha: str
    path: str
    mime: str
    size: int
    caption: str
    name: str
    only_for: list[UUID]
    use_count: int
    created_at: datetime

    def to_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "caption": self.caption, "mime": self.mime,
                "only_for": [str(c) for c in self.only_for], "use_count": self.use_count}


_COLS = "id, account_id, sha, path, mime, size, caption, name, only_for, use_count, created_at"


def _row(r) -> Sticker:
    d = dict(r)
    d["only_for"] = list(d["only_for"] or [])
    return Sticker(**d)


def sniff(data: bytes) -> tuple[str, str]:
    """认图：返回 (mime, 后缀)；不是图、太大都报人话。"""
    try:
        with Image.open(io.BytesIO(data)) as im:
            fmt = im.format
    except Exception as e:
        raise StickerError("这个文件不是图片") from e
    if fmt not in FORMATS:
        raise StickerError("表情包只认 PNG / JPEG / GIF / WebP")
    if len(data) > (MAX_GIF_BYTES if fmt == "GIF" else MAX_BYTES):
        raise StickerError("这张太大了（动图最多 5MB，别的 2MB）")
    return FORMATS[fmt]


def still(data: bytes) -> tuple[str, bytes]:
    """给看图模型的那一张：动图取第一帧，一律转 PNG。"""
    with Image.open(io.BytesIO(data)) as im:
        im.seek(0)
        out = io.BytesIO()
        im.convert("RGBA").save(out, "PNG")
    return "image/png", out.getvalue()


async def _embed(pool, embedder, sticker_id: int, name: str, caption: str) -> None:
    text = " ".join(x for x in (name, caption) if x).strip()
    vec = await embed_one(embedder, text) if text else None
    await pool.execute("UPDATE stickers SET embedding = $2 WHERE id = $1", sticker_id, vec)


async def add(pool, embedder, files_dir: Path, account: UUID, *, data: bytes, name: str = "", caption: str = "",
              lang: str = "zh") -> tuple[Sticker, bool]:
    """收一张。返回 (这张, 是不是新收的)；同一张收过就返回原来那张。"""
    mime, ext = sniff(data)
    sha = hashlib.sha256(data).hexdigest()
    old = await pool.fetchrow(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 AND sha = $2", account, sha)
    if old is not None:
        return _row(old), False
    if await pool.fetchval("SELECT count(*) FROM stickers WHERE account_id = $1", account) >= MAX_STICKERS:
        raise StickerError(f"表情包最多 {MAX_STICKERS} 张，先删几张")
    if not caption:                                   # 这张图以前在聊天里看过：直接用那段描述
        caption = await pool.fetchval("SELECT caption FROM image_captions WHERE account_id = $1 AND sha = $2 AND lang = $3",
                                      account, sha, lang) or ""
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"sticker-{uuid.uuid4()}{ext}"
    path.write_bytes(data)
    r = await pool.fetchrow(
        f"""INSERT INTO stickers (account_id, sha, path, mime, size, caption, name) VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING {_COLS}""", account, sha, str(path), mime, len(data), caption[:CAPTION_MAX],
        (name or "").strip()[:NAME_MAX])
    s = _row(r)
    if s.caption or s.name:
        await _embed(pool, embedder, s.id, s.name, s.caption)
    return s, True


async def get(pool, account: UUID, sticker_id: int) -> Sticker | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM stickers WHERE id = $1 AND account_id = $2", sticker_id, account)
    return _row(r) if r else None


async def list_all(pool, account: UUID) -> list[Sticker]:
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 ORDER BY created_at DESC, id DESC", account)
    return [_row(r) for r in rows]


async def update(pool, embedder, account: UUID, sticker_id: int, *, name: str | None = None, caption: str | None = None,
                 only_for: list[UUID] | None = None) -> Sticker:
    s = await get(pool, account, sticker_id)
    if s is None:
        raise LookupError("没有这张")
    if only_for is not None:
        mine = {r["id"] for r in await pool.fetch("SELECT id FROM companions WHERE account_id = $1", account)}
        if any(c not in mine for c in only_for):
            raise StickerError("没有这个联系人")
    r = await pool.fetchrow(
        f"""UPDATE stickers SET name = COALESCE($3, name), caption = COALESCE($4, caption),
                   only_for = COALESCE($5::uuid[], only_for)
            WHERE id = $1 AND account_id = $2 RETURNING {_COLS}""",
        sticker_id, account, name.strip()[:NAME_MAX] if name is not None else None,
        " ".join(caption.split())[:CAPTION_MAX] if caption is not None else None,
        list(dict.fromkeys(only_for)) if only_for is not None else None)
    s = _row(r)
    if name is not None or caption is not None:
        await _embed(pool, embedder, s.id, s.name, s.caption)
    return s


async def delete(pool, account: UUID, sticker_id: int) -> bool:
    path = await pool.fetchval("DELETE FROM stickers WHERE id = $1 AND account_id = $2 RETURNING path", sticker_id, account)
    if path is None:
        return False
    Path(path).unlink(missing_ok=True)
    return True


async def search(pool, embedder, account: UUID, companion: UUID, query: str, *, limit: int = SEARCH_LIMIT) -> list[Sticker]:
    """它按意思找：向量最像的 + 名字 / 描述里有这个词的，只给别人的那几张不算；没写好描述的也不给（它不知道是什么）。"""
    where = "account_id = $1 AND caption <> '' AND (cardinality(only_for) = 0 OR $2 = ANY(only_for))"
    q = (query or "").strip()
    vec = await embed_one(embedder, q) if q else None
    hits: dict[int, float] = {}
    if vec is not None:
        for r in await pool.fetch(f"SELECT id, 1 - (embedding <=> $3) AS sim FROM stickers WHERE {where} "
                                  f"AND embedding IS NOT NULL ORDER BY embedding <=> $3 LIMIT $4",
                                  account, companion, vec, limit * 2):
            hits[r["id"]] = float(r["sim"])
    if q:
        for r in await pool.fetch(f"SELECT id FROM stickers WHERE {where} AND (name ILIKE $3 OR caption ILIKE $3) LIMIT $4",
                                  account, companion, f"%{q}%", limit):
            hits[r["id"]] = hits.get(r["id"], 0.0) + 1.0          # 字面上碰到的排前面
    if not hits:
        return []
    ids = sorted(hits, key=lambda i: -hits[i])[:limit]
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE id = ANY($1::bigint[])", ids)
    by = {r["id"]: _row(r) for r in rows}
    return [by[i] for i in ids if i in by]


async def usable(pool, account: UUID, companion: UUID, sticker_id: int) -> Sticker | None:
    """这个联系人能不能发这张（没写描述的也能发，只是它搜不到）。"""
    r = await pool.fetchrow(f"SELECT {_COLS} FROM stickers WHERE id = $1 AND account_id = $2 "
                            f"AND (cardinality(only_for) = 0 OR $3 = ANY(only_for))", sticker_id, account, companion)
    return _row(r) if r else None


async def mark_used(pool, sticker_id: int, now: datetime) -> None:
    await pool.execute("UPDATE stickers SET use_count = use_count + 1, last_used_at = $2 WHERE id = $1", sticker_id, now)


async def caption_pending(deps, account: UUID, now: datetime, *, limit: int = 20) -> int:
    """没描述的写描述（上传后在后台跑）。用主联系人的钥匙（会看图的自己看，不会的找会看图的 key / 我们的）。返回写了几张。"""
    from . import accounts, archive, vision
    from .auth import TrialOver
    from .scope import Scope
    from .settings import Settings
    from .turn import get_adapter, resolve_route
    pool = deps.pool
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 AND caption = '' ORDER BY id LIMIT $2",
                            account, limit)
    if not rows:
        return 0
    comps = await accounts.list_companions(pool, account)
    if not comps:
        return 0
    s = Settings.from_dict(await archive.get_settings(pool, comps[0]))
    scope = Scope(account, comps[0], None)
    try:
        chat = await resolve_route(deps.keys, scope)
    except TrialOver:
        chat = getattr(deps.keys, "trial", None)
    route = None
    if chat is not None:
        route, _ = await vision.describer_for(deps, scope, chat)
    if route is None:
        return 0
    day = now.astimezone().date() if now.tzinfo else date.today()
    done = 0
    for st in map(_row, rows):
        try:
            mime, data = still(Path(st.path).read_bytes())
            caption = await vision.look(deps, scope, route, mime, data, s.lang, day, lambda r: get_adapter(deps, r),
                                        prompt=PROMPT.get(s.lang, PROMPT["en"]))
        except Exception:
            log.exception("sticker %s caption failed", st.id)
            continue
        if not caption:
            continue
        await pool.execute("UPDATE stickers SET caption = $2 WHERE id = $1", st.id, caption[:CAPTION_MAX])
        await vision.remember_caption(pool, account, st.sha, s.lang, caption[:CAPTION_MAX], "sticker")
        await _embed(pool, deps.embedder, st.id, st.name, caption)
        done += 1
    return done


async def to_attachment(pool, files_dir: Path, account: UUID, conversation: UUID, sticker_id: int):
    """TA 从面板发一张：复制一份变成这个窗口的附件（删窗口删附件不会删到表情包），描述带上、标成表情包。"""
    from .attachments import _COLS as ACOLS, _row as arow
    s = await get(pool, account, sticker_id)
    if s is None:
        return None
    aid = uuid.uuid4()
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"{aid}{Path(s.path).suffix}"
    shutil.copyfile(s.path, path)
    r = await pool.fetchrow(
        f"""INSERT INTO attachments (id, account_id, conversation_id, kind, name, mime, size, path, caption, caption_source,
                                     sha, sticker_id)
            VALUES ($1, $2, $3, 'image', $4, $5, $6, $7, $8, 'sticker', $9, $10) RETURNING {ACOLS}""",
        aid, account, conversation, s.name, s.mime, s.size, str(path), s.caption, s.sha, s.id)
    return arow(r)
