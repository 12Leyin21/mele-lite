"""朋友圈（10-01 Tilia，设计 specs/2026-10-01-moments-design.md；移植自之前自用的 App 的中继 moments.py，我们自己写的）。

「朋友圈不是推送，是它有一个可以自言自语的角落」——不进聊天流、不推送，TA 路过才看见。
author / who：'user' = TA，否则是联系人编号（文本）。
- TA 发 → 每个联系人到点来刷（moment_visits）；联系人发 → 别的联系人来刷（peer，只给付费）。
- TA 评论：评在某个联系人的动态下、或者回的是它的评论 → 它到点来回。
- 联系人评论：评给另一个联系人（它的动态 / 回它的评论）→ 那个联系人来回，来回最多两轮（ROUNDS_MAX），TA 一插话重新算。"""
from __future__ import annotations

import hashlib
import json
import random
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID

from . import accounts, archive
from .persona import Persona
from .settings import Settings

USER = "user"
MAX_IMAGES = 9
CONTENT_MAX = 1000
COMMENT_MAX = 300
NOTE_MAX = 500
SIGNATURE_MAX = 60
ROUNDS_MAX = 2
FREE_DAILY = 3                       # 免费用户每天最多被回几次（10-01 Tilia：我们家不开慈善）
THREAD_LIMIT = 10

# 分钟：(最早, 最常见, 最晚)——照之前自用的 App，三角分布：大多落在中间，偶尔很快或很晚
DELAY_USER_POST = (15, 45, 180)
DELAY_PEER_POST = (20, 70, 240)
DELAY_COMMENT = (5, 15, 60)


def delay(spec: tuple, rng: random.Random | None = None) -> timedelta:
    lo, mode, hi = spec
    return timedelta(minutes=(rng or random).triangular(lo, hi, mode))


@dataclass
class Moment:
    id: int
    account_id: UUID
    author: str
    content: str
    context_note: str
    images: list
    image_desc: str
    created_at: datetime
    likes: list[str] = field(default_factory=list)
    comments: list[dict] = field(default_factory=list)


_COLS = "id, account_id, author, content, context_note, images, image_desc, created_at"


def _moment(r) -> Moment:
    d = dict(r)
    d["images"] = json.loads(d["images"]) if isinstance(d["images"], str) else list(d["images"] or [])
    return Moment(**d)


async def _fill(pool, ms: list[Moment]) -> list[Moment]:
    if not ms:
        return ms
    ids = [m.id for m in ms]
    likes = await pool.fetch("SELECT moment_id, who FROM moment_likes WHERE moment_id = ANY($1::bigint[]) ORDER BY created_at",
                             ids)
    comments = await pool.fetch("SELECT id, moment_id, author, content, reply_to, created_at FROM moment_comments "
                                "WHERE moment_id = ANY($1::bigint[]) ORDER BY id", ids)
    by = {m.id: m for m in ms}
    for r in likes:
        by[r["moment_id"]].likes.append(r["who"])
    for r in comments:
        by[r["moment_id"]].comments.append(dict(r))
    return ms


async def get(pool, account: UUID, moment_id: int) -> Moment | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM moments WHERE id = $1 AND account_id = $2", moment_id, account)
    return (await _fill(pool, [_moment(r)]))[0] if r else None


async def feed(pool, account: UUID, *, author: str | None = None, before: int | None = None, limit: int = 20) -> list[Moment]:
    rows = await pool.fetch(
        f"""SELECT {_COLS} FROM moments WHERE account_id = $1 AND ($2::text IS NULL OR author = $2)
            AND ($3::bigint IS NULL OR id < $3) ORDER BY id DESC LIMIT $4""",
        account, author, before, max(1, min(limit, 50)))
    return await _fill(pool, [_moment(r) for r in rows])


async def _companions(pool, account: UUID) -> list[UUID]:
    return await accounts.list_companions(pool, account)


async def _visit(pool, account: UUID, companion: UUID, moment_id: int, due: datetime, *, comment_id: int | None = None,
                 peer: bool = False, round_: int = 0) -> None:
    await pool.execute("""INSERT INTO moment_visits (account_id, companion_id, moment_id, comment_id, peer, round, due_at)
                          VALUES ($1, $2, $3, $4, $5, $6, $7)""", account, companion, moment_id, comment_id, peer, round_, due)


async def post(pool, account: UUID, author: str, *, content: str, now: datetime, images: list | None = None,
               context_note: str = "", rng: random.Random | None = None) -> Moment:
    """发一条，并给该来刷的联系人排上（TA 发的：所有联系人；联系人发的：别的联系人，peer）。"""
    content = (content or "").strip()[:CONTENT_MAX]
    images = list(images or [])[:MAX_IMAGES]
    if not content and not images:
        raise ValueError("写点什么，或者放张图")
    comps = await _companions(pool, account)
    if author != USER and UUID(author) not in comps:
        raise PermissionError("没有这个联系人")
    r = await pool.fetchrow(
        f"""INSERT INTO moments (account_id, author, content, context_note, images, created_at)
            VALUES ($1, $2, $3, $4, $5::jsonb, $6) RETURNING {_COLS}""",
        account, author, content, (context_note or "").strip()[:NOTE_MAX], json.dumps(images), now)
    m = _moment(r)
    for c in comps:
        if str(c) == author:
            continue
        peer = author != USER
        await _visit(pool, account, c, m.id, now + delay(DELAY_PEER_POST if peer else DELAY_USER_POST, rng), peer=peer)
    return m


async def delete(pool, account: UUID, moment_id: int, *, author: str = USER) -> bool:
    paths = await pool.fetchval("DELETE FROM moments WHERE id = $1 AND account_id = $2 AND author = $3 RETURNING images",
                                moment_id, account, author)
    if paths is None:
        return False
    for img in (json.loads(paths) if isinstance(paths, str) else paths):
        Path(img.get("path", "")).unlink(missing_ok=True)
    return True


async def like(pool, account: UUID, moment_id: int, who: str, liked: bool = True, *, now: datetime | None = None) -> bool:
    if await get(pool, account, moment_id) is None:
        return False
    if liked:
        await pool.execute("INSERT INTO moment_likes (moment_id, who, created_at) VALUES ($1, $2, COALESCE($3, now())) "
                           "ON CONFLICT DO NOTHING", moment_id, who, now)
    else:
        await pool.execute("DELETE FROM moment_likes WHERE moment_id = $1 AND who = $2", moment_id, who)
    return True


async def comment(pool, account: UUID, moment_id: int, author: str, content: str, *, now: datetime,
                  reply_to: int | None = None, round_: int = 0, rng: random.Random | None = None) -> dict:
    """留一条评论，并排上该来回的那个联系人。"""
    m = await get(pool, account, moment_id)
    if m is None:
        raise LookupError("没有这条")
    content = (content or "").strip()[:COMMENT_MAX]
    if not content:
        raise ValueError("评论是空的")
    target = next((c for c in m.comments if c["id"] == reply_to), None) if reply_to else None
    if reply_to and target is None:
        reply_to = None
    r = await pool.fetchrow("""INSERT INTO moment_comments (moment_id, author, content, reply_to, created_at)
                               VALUES ($1, $2, $3, $4, $5) RETURNING id, moment_id, author, content, reply_to, created_at""",
                            moment_id, author, content, reply_to, now)
    to = target["author"] if target else (m.author if m.author != author else None)   # 这条是说给谁的
    if to and to != USER and to != author:
        peer = author != USER
        nxt = round_ + 1 if peer else 0
        if not peer or nxt <= ROUNDS_MAX:
            await _visit(pool, account, UUID(to), moment_id, now + delay(DELAY_COMMENT, rng), comment_id=r["id"],
                         peer=peer, round_=nxt)
    return dict(r)


async def delete_comment(pool, account: UUID, comment_id: int, *, author: str = USER) -> bool:
    done = await pool.execute("""DELETE FROM moment_comments c USING moments m WHERE c.id = $1 AND c.moment_id = m.id
                                 AND m.account_id = $2 AND c.author = $3""", comment_id, account, author)
    return done.endswith(" 1")


# ── 签名、封面 ──

async def profile(pool, account: UUID, who: str) -> dict:
    r = await pool.fetchrow("SELECT signature, cover_path FROM moment_profiles WHERE account_id = $1 AND who = $2",
                            account, who)
    return {"signature": r["signature"] if r else "", "cover_path": r["cover_path"] if r else ""}


async def set_signature(pool, account: UUID, who: str, signature: str) -> str:
    sig = " ".join((signature or "").split())[:SIGNATURE_MAX]
    await pool.execute("""INSERT INTO moment_profiles (account_id, who, signature) VALUES ($1, $2, $3)
                          ON CONFLICT (account_id, who) DO UPDATE SET signature = EXCLUDED.signature""", account, who, sig)
    return sig


async def set_cover(pool, files_dir: Path, account: UUID, who: str, data: bytes) -> str:
    old = (await profile(pool, account, who))["cover_path"]
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"cover-{uuid.uuid4()}.jpg"
    path.write_bytes(data)
    await pool.execute("""INSERT INTO moment_profiles (account_id, who, cover_path) VALUES ($1, $2, $3)
                          ON CONFLICT (account_id, who) DO UPDATE SET cover_path = EXCLUDED.cover_path""",
                       account, who, str(path))
    if old:
        Path(old).unlink(missing_ok=True)
    return str(path)


def save_image(files_dir: Path, data: bytes) -> dict:
    from .attachments import _image
    blob = _image(data)
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"moment-{uuid.uuid4()}.jpg"
    path.write_bytes(blob)
    return {"path": str(path), "mime": "image/jpeg", "sha": hashlib.sha256(data).hexdigest()}


# ── 名字、给 app 的样子 ──

async def names(pool, account: UUID) -> dict[str, str]:
    comps = await _companions(pool, account)
    out = {}
    for c in comps:
        out[str(c)] = Persona.from_dict(await archive.get_persona(pool, c)).name
    me = ""
    if comps:
        me = Settings.from_dict(await archive.get_settings(pool, comps[0])).user_name
    out[USER] = me or "我"
    return out


def to_dict(m: Moment, nm: dict[str, str]) -> dict:
    by_id = {c["id"]: c for c in m.comments}
    return {"id": m.id, "author": m.author, "name": nm.get(m.author, ""), "content": m.content,
            "images": len(m.images), "created_at": m.created_at.isoformat(),
            "likes": [{"who": w, "name": nm.get(w, "")} for w in m.likes],
            "comments": [{"id": c["id"], "author": c["author"], "name": nm.get(c["author"], ""), "content": c["content"],
                          "reply_to": c["reply_to"],
                          "reply_to_name": nm.get(by_id[c["reply_to"]]["author"], "") if c["reply_to"] in by_id else None,
                          "created_at": c["created_at"].isoformat()} for c in m.comments]}


async def activity(pool, account: UUID, since: datetime | None) -> dict:
    """「N 条新互动」（微信那颗气泡）：since 之后联系人在 TA 的动态上点的赞、对 TA 说的评论；另数一下联系人发的新动态。"""
    nm = await names(pool, account)
    likes = await pool.fetch(
        """SELECT l.who, l.created_at, m.id AS moment_id, m.content FROM moment_likes l JOIN moments m ON m.id = l.moment_id
           WHERE m.account_id = $1 AND m.author = $2 AND l.who <> $2 AND ($3::timestamptz IS NULL OR l.created_at > $3)""",
        account, USER, since)
    comments = await pool.fetch(
        """SELECT c.author, c.content, c.created_at, m.id AS moment_id, m.content AS post FROM moment_comments c
           JOIN moments m ON m.id = c.moment_id LEFT JOIN moment_comments p ON p.id = c.reply_to
           WHERE m.account_id = $1 AND c.author <> $2 AND ($3::timestamptz IS NULL OR c.created_at > $3)
             AND ((m.author = $2 AND c.reply_to IS NULL) OR p.author = $2)""", account, USER, since)
    new_posts = await pool.fetchval("SELECT count(*) FROM moments WHERE account_id = $1 AND author <> $2 "
                                    "AND ($3::timestamptz IS NULL OR created_at > $3)", account, USER, since)
    items = [{"kind": "like", "who": r["who"], "name": nm.get(r["who"], ""), "at": r["created_at"].isoformat(),
              "moment_id": r["moment_id"], "post": r["content"], "content": None} for r in likes]
    items += [{"kind": "comment", "who": r["author"], "name": nm.get(r["author"], ""), "at": r["created_at"].isoformat(),
               "moment_id": r["moment_id"], "post": r["post"], "content": r["content"]} for r in comments]
    items.sort(key=lambda x: x["at"], reverse=True)
    return {"count": len(items), "new_posts": new_posts, "items": items[:50]}
