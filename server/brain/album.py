"""相册（10-02，照之前自用的 App photo_memories + home_album；计划 docs/plans/2026-10-02-album.md）。

- 进相册要经它的手：聊天里 TA 发的图，它觉得值得留才 keep，同时写三样（caption / felt / why），可以加 thoughts。
- TA 自己加照片（一次最多 9 张 + 一段话）：进来就在相册里（「在看」），一分钟后它单独一小轮看完写字（album_look.py）。
- 三本：全部（不含隐私）/ 收藏 / 隐私。隐私的默认一律不给，要明着要 secret 才给——相册可能被别人拿在手上翻（之前自用的 App 09-01 的边界）。
- 照片单独存一份（附件目录下的 album/），聊天倒回、窗口删了也还在。"""
from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID

from . import attachments

MAX_ADD = 9
LOOK_DELAY = timedelta(seconds=60)
LIMITS = {"caption": 500, "felt": 500, "why": 500, "thoughts": 2000}
BOOKS = ("all", "starred", "secret")


class AlbumError(ValueError):
    pass


@dataclass
class Photo:
    id: int
    companion_id: UUID
    path: str
    source: str
    taken_at: datetime
    caption: str
    felt: str
    why: str
    thoughts: str
    note: str
    batch: str
    starred: bool
    secret: bool
    look_status: str

    def public(self) -> dict:
        return {"id": self.id, "companion_id": str(self.companion_id), "source": self.source,
                "taken_at": self.taken_at.isoformat(), "caption": self.caption, "felt": self.felt, "why": self.why,
                "thoughts": self.thoughts, "note": self.note, "batch": self.batch, "starred": self.starred,
                "secret": self.secret, "looking": self.look_status in ("pending", "asked"),
                "url": f"album/{self.id}/image", "thumb": f"album/{self.id}/image?thumb=1"}


_COLS = "id, companion_id, path, source, taken_at, caption, felt, why, thoughts, note, batch, starred, secret, look_status"


def _row(r) -> Photo:
    return Photo(**dict(r))


def _clean(fields: dict) -> dict:
    return {k: str(fields[k] or "").strip()[:n] for k, n in LIMITS.items() if fields.get(k) is not None}


def album_dir(files_dir: Path) -> Path:
    d = files_dir / "album"
    d.mkdir(parents=True, exist_ok=True)
    return d


THUMB_SIDE = 480


def thumb(path: str) -> str:
    """长边 480 的小图，跟原图放一起（xxx.jpg → xxx.thumb.jpg）；没有就现做一张。"""
    src = Path(path)
    out = src.with_suffix(".thumb.jpg")
    if not out.exists():
        import io
        from PIL import Image
        img = Image.open(src).convert("RGB")
        img.thumbnail((THUMB_SIDE, THUMB_SIDE))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=80)
        out.write_bytes(buf.getvalue())
    return str(out)


def _unlink(path: str) -> None:
    Path(path).unlink(missing_ok=True)
    Path(path).with_suffix(".thumb.jpg").unlink(missing_ok=True)


async def list_all(pool, account: UUID, *, book: str = "all", companion: UUID | None = None) -> list[Photo]:
    if book not in BOOKS:
        raise AlbumError("book 只能是 all / starred / secret")
    where = ["account_id = $1", "secret" if book == "secret" else "NOT secret"]
    args: list = [account]
    if book == "starred":
        where.append("starred")
    if companion:
        args.append(companion)
        where.append(f"companion_id = ${len(args)}")
    rows = await pool.fetch(f"SELECT {_COLS} FROM album_photos WHERE {' AND '.join(where)} ORDER BY taken_at DESC, id DESC",
                            *args)
    return [_row(r) for r in rows]


async def get(pool, account: UUID, pid: int) -> Photo | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM album_photos WHERE account_id = $1 AND id = $2", account, pid)
    return _row(r) if r else None


async def _recent_image(pool, account: UUID, companion: UUID, conversation: UUID | None, which: int):
    """TA 最近发的第 which 张图（1 = 最近那张）。在这个窗口里找；不知道窗口就找这个联系人所有不无痕的窗口。表情包不算。"""
    scope = "a.conversation_id = $3" if conversation else \
        "a.conversation_id IN (SELECT id FROM conversations WHERE companion_id = $3 AND NOT incognito)"
    return await pool.fetchrow(
        f"""SELECT a.path, a.sha, m.created_at FROM attachments a JOIN chat_messages m ON m.id = a.message_id
            WHERE a.account_id = $1 AND a.kind = 'image' AND a.sticker_id IS NULL AND m.role = 'user' AND {scope}
            ORDER BY a.created_at DESC OFFSET $2 LIMIT 1""",
        account, max(0, which - 1), conversation or companion)


async def keep(pool, account: UUID, companion: UUID, conversation: UUID | None, *, which: int = 1,
               fields: dict, now: datetime) -> Photo:
    """它从聊天里收一张进相册，同时写字。同一张收过的就是改字。"""
    f = _clean(fields)
    if not f.get("caption"):
        raise AlbumError("收进相册要写 caption（这是哪一刻）")
    att = await _recent_image(pool, account, companion, conversation, which)
    if att is None:
        raise AlbumError("最近没有 TA 发的照片" if which <= 1 else f"往前数第 {which} 张没有")
    src = Path(att["path"])
    data = src.read_bytes()
    sha = att["sha"] or hashlib.sha256(data).hexdigest()
    dest = album_dir(src.parent) / f"{uuid.uuid4()}.jpg"
    old = await pool.fetchrow("SELECT id FROM album_photos WHERE account_id = $1 AND companion_id = $2 AND sha = $3",
                              account, companion, sha)
    if old:
        return await write(pool, account, companion, old["id"], f)
    dest.write_bytes(data)
    r = await pool.fetchrow(
        f"""INSERT INTO album_photos (account_id, companion_id, sha, path, source, taken_at, caption, felt, why, thoughts,
                                      look_status, created_at)
            VALUES ($1, $2, $3, $4, 'chat', $5, $6, $7, $8, $9, 'done', $10) RETURNING {_COLS}""",
        account, companion, sha, str(dest), att["created_at"], f.get("caption", ""), f.get("felt", ""), f.get("why", ""),
        f.get("thoughts", ""), now)
    return _row(r)


async def write(pool, account: UUID, companion: UUID, pid: int, fields: dict) -> Photo:
    """给一张写字 / 改字（只能写自己名下的）。写了 caption 或观后感就算看完了。"""
    f = _clean(fields)
    if not f:
        raise AlbumError("要写什么？caption / felt / why / thoughts")
    sets = [f"{k} = ${i + 4}" for i, k in enumerate(f)]
    if "caption" in f or "thoughts" in f:
        sets.append("look_status = 'done'")
    r = await pool.fetchrow(f"UPDATE album_photos SET {', '.join(sets)} WHERE account_id = $1 AND companion_id = $2 AND id = $3 "
                            f"RETURNING {_COLS}", account, companion, pid, *f.values())
    if r is None:
        raise AlbumError(f"相册里没有 #{pid}")
    return _row(r)


async def look(pool, account: UUID, companion: UUID, pid: int | None, rng) -> str:
    """翻一张旧照片：给编号看那张，不给随机一张（隐私那本里的不翻）。返回当时写的字。"""
    if pid:
        p = await get(pool, account, pid)
        if p is None or p.companion_id != companion or p.secret:
            return f"没有 #{pid}（或者它在隐私那本里）。"
    else:
        rows = await pool.fetch(f"SELECT {_COLS} FROM album_photos WHERE account_id = $1 AND companion_id = $2 "
                                "AND NOT secret AND caption <> ''", account, companion)
        if not rows:
            return "相册还是空的。"
        p = _row(rng.choice(rows))
    lines = [f"#{p.id}（{p.taken_at.date().isoformat()}）"]
    for label, v in (("TA 写的", p.note), ("你的图注", p.caption), ("你当时的第一下", p.felt), ("为什么留", p.why),
                     ("观后感", p.thoughts)):
        if v:
            lines.append(f"{label}：{v}")
    if len(lines) == 1:
        lines.append("（还没写字）")
    return "\n".join(lines)


async def add_mine(pool, files_dir: Path, account: UUID, companion: UUID, images: list[bytes], note: str,
                   now: datetime) -> list[Photo]:
    """TA 自己加照片：一次最多 9 张 + 一段话。进来就在相册里，一分钟后它看（album_look）。同一张加过的跳过。"""
    if not images:
        raise AlbumError("没有照片")
    if len(images) > MAX_ADD:
        raise AlbumError(f"一次最多 {MAX_ADD} 张")
    batch, out = secrets.token_hex(6), []
    for data in images:
        if len(data) > attachments.IMAGE_MAX_BYTES:
            raise AlbumError("图片太大了（最多 10MB）")
        blob = attachments._image(data)
        sha = hashlib.sha256(data).hexdigest()
        dest = album_dir(files_dir) / f"{uuid.uuid4()}.jpg"
        r = await pool.fetchrow(
            f"""INSERT INTO album_photos (account_id, companion_id, sha, path, source, taken_at, note, batch,
                                          look_status, look_due, created_at)
                VALUES ($1, $2, $3, $4, 'mine', $5, $6, $7, 'pending', $8, $5)
                ON CONFLICT (account_id, companion_id, sha) DO NOTHING RETURNING {_COLS}""",
            account, companion, sha, str(dest), now, note.strip()[:1000], batch, now + LOOK_DELAY)
        if r:
            dest.write_bytes(blob)
            out.append(_row(r))
    return out


async def set_flags(pool, account: UUID, pid: int, *, starred: bool | None = None, secret: bool | None = None) -> Photo | None:
    r = await pool.fetchrow(
        f"""UPDATE album_photos SET starred = COALESCE($3, starred), secret = COALESCE($4, secret)
            WHERE account_id = $1 AND id = $2 RETURNING {_COLS}""", account, pid, starred, secret)
    return _row(r) if r else None


async def delete(pool, account: UUID, pid: int) -> bool:
    path = await pool.fetchval("DELETE FROM album_photos WHERE account_id = $1 AND id = $2 RETURNING path", account, pid)
    if path is None:
        return False
    _unlink(path)
    return True


async def wipe(pool, companion: UUID) -> None:
    """删联系人：它名下的照片连文件一起删。"""
    for r in await pool.fetch("DELETE FROM album_photos WHERE companion_id = $1 RETURNING path", companion):
        _unlink(r["path"])


async def export(pool, account: UUID) -> list[dict]:
    rows = await pool.fetch(f"SELECT {_COLS} FROM album_photos WHERE account_id = $1 ORDER BY taken_at", account)
    return [{k: v for k, v in _row(r).public().items() if k not in ("url", "thumb")} for r in rows]
