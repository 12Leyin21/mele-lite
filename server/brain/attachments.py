"""附件：TA 发来的照片和文件（2026-09-27，iOS 第一块第 3 步；设计 specs/2026-09-27-ios-block1-chat-design.md 第三节）。

- 照片：手机先压到长边约 1600 再传；这里再兜一道——转成 JPEG、长边超 2048 就缩。原图存盘（开发时 server/.local/files/）。
  每张图要一段描述（第 4 步：会看图的模型只在发图那轮看原图，之后历史里都用描述）。
- 文件：先认 PDF / 纯文本 / Markdown，抽出字（太长截到 1 万字）塞给它；历史里存的也是抽出的字。
上传时还没挂到消息上（message_id 空）；发消息那一轮把它们挂到 TA 那句上。删窗口、删号时文件一起删。"""
from __future__ import annotations

import hashlib
import re
import io
import uuid
from dataclasses import dataclass, replace
from pathlib import Path
from uuid import UUID

from PIL import Image
from pypdf import PdfReader

from .archive import StoredMsg

IMAGE_MAX_BYTES = 10 * 1024 * 1024
FILE_MAX_BYTES = 20 * 1024 * 1024
IMAGE_LONG_SIDE = 2048
TEXT_MAX_CHARS = 10_000
IMAGE_MIMES = ("image/jpeg", "image/png", "image/webp")
TEXT_EXT = {".txt": "text/plain", ".md": "text/markdown", ".markdown": "text/markdown"}

NOTE = {
    "zh": {"image": "〔TA 发了一张图片：{c}〕", "image_blank": "〔TA 发了一张图片（还没看清是什么）〕",
           "sticker": "〔TA 发了一个表情包：{c}〕",
           "file": "〔TA 发了文件「{n}」，内容：\n{t}\n〕", "cut": "（后面太长，截掉了）", "voice_blank": "〔语音〕"},
    "en": {"image": "〔They sent a photo: {c}〕", "image_blank": "〔They sent a photo (not described yet)〕",
           "sticker": "〔They sent a sticker: {c}〕",
           "file": "〔They sent the file \"{n}\":\n{t}\n〕", "cut": "(the rest was too long and was cut)",
           "voice_blank": "〔voice message〕"},
}


class AttachmentError(ValueError):
    """给用户看的人话。"""


@dataclass
class Attachment:
    id: UUID
    kind: str                # image / file / voice（10-03 TA 的语音）
    name: str
    mime: str
    size: int
    path: str
    text: str                # 文件抽出的字
    caption: str             # 图片的描述（第 4 步写）
    message_id: int | None
    sha: str = ""            # 原始字节的指纹（10-01：同一张图只读一次）
    sticker_id: int | None = None   # TA 从表情包面板发的（10-01）

    def public(self) -> dict:
        out = {"id": str(self.id), "kind": self.kind, "name": self.name, "mime": self.mime, "size": self.size}
        if self.kind == "voice":            # 语音（10-03）：时长写在名字里 voice-23s.m4a
            m = re.match(r"voice-(\d+)s", self.name)
            out["seconds"] = int(m.group(1)) if m else 0
        return out


_COLS = "id, kind, name, mime, size, path, text, caption, message_id, sha, sticker_id"


def _row(r) -> Attachment:
    return Attachment(**dict(r))


def _image(data: bytes) -> bytes:
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception as e:
        raise AttachmentError("这张图打不开") from e
    img = img.convert("RGB")
    if max(img.size) > IMAGE_LONG_SIDE:
        img.thumbnail((IMAGE_LONG_SIDE, IMAGE_LONG_SIDE))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=85)
    return out.getvalue()


def _pdf_text(data: bytes) -> str:
    try:
        reader = PdfReader(io.BytesIO(data))
        return "\n".join((p.extract_text() or "") for p in reader.pages)
    except Exception as e:
        raise AttachmentError("这个 PDF 读不出来") from e


def extract(name: str, mime: str, data: bytes) -> tuple[str, str, bytes, str]:
    """(kind, mime, 要存盘的字节, 抽出的字)。不认的类型报 AttachmentError。"""
    ext = Path(name or "").suffix.lower()
    if mime in IMAGE_MIMES or ext in (".jpg", ".jpeg", ".png", ".webp"):
        if len(data) > IMAGE_MAX_BYTES:
            raise AttachmentError("图片太大了（最多 10MB）")
        return "image", "image/jpeg", _image(data), ""
    if len(data) > FILE_MAX_BYTES:
        raise AttachmentError("文件太大了（最多 20MB）")
    if mime == "application/pdf" or ext == ".pdf":
        return "file", "application/pdf", data, _pdf_text(data)
    if ext in TEXT_EXT or mime in ("text/plain", "text/markdown"):
        return "file", TEXT_EXT.get(ext, mime), data, data.decode("utf-8", errors="replace")
    raise AttachmentError("先只认照片、PDF、文本和 Markdown")


async def save(pool, files_dir: Path, *, account: UUID, conversation: UUID, name: str, mime: str,
               data: bytes) -> Attachment:
    kind, mime, blob, text = extract(name, mime, data)
    aid = uuid.uuid4()
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"{aid}{'.jpg' if kind == 'image' else Path(name).suffix.lower() or '.bin'}"
    path.write_bytes(blob)
    r = await pool.fetchrow(
        f"""INSERT INTO attachments (id, account_id, conversation_id, kind, name, mime, size, path, text, sha)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING {_COLS}""",
        aid, account, conversation, kind, (name or "")[:200], mime, len(blob), str(path), text.strip(),
        hashlib.sha256(data).hexdigest() if kind == "image" else "")
    return _row(r)


async def get(pool, account: UUID, attachment_id: UUID) -> Attachment | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM attachments WHERE id = $1 AND account_id = $2", attachment_id, account)
    return _row(r) if r else None


async def claim(pool, conversation: UUID, ids: list[UUID], message_id: int) -> list[Attachment]:
    """把这一轮带的附件挂到 TA 那句上（只认这个窗口里、还没挂过的）。"""
    rows = await pool.fetch(
        f"""UPDATE attachments SET message_id = $3 WHERE conversation_id = $1 AND id = ANY($2::uuid[])
            AND message_id IS NULL RETURNING {_COLS}""", conversation, list(ids), message_id)
    return [_row(r) for r in rows]


async def for_messages(pool, ids: list[int]) -> dict[int, list[Attachment]]:
    if not ids:
        return {}
    rows = await pool.fetch(f"SELECT {_COLS} FROM attachments WHERE message_id = ANY($1::bigint[]) ORDER BY created_at",
                            list(ids))
    out: dict[int, list[Attachment]] = {}
    for r in rows:
        out.setdefault(r["message_id"], []).append(_row(r))
    return out


async def set_caption(pool, attachment_id: UUID, caption: str) -> None:
    await pool.execute("UPDATE attachments SET caption = $2 WHERE id = $1", attachment_id, caption)


def note(a: Attachment, lang: str) -> str:
    """这个附件在它看到的文字里长什么样：图 = 描述，文件 = 抽出的字（截到 1 万字）。"""
    t = NOTE[lang]
    if a.kind == "image" and a.sticker_id and a.caption:
        return t["sticker"].format(c=a.caption)
    if a.kind == "image":
        return t["image"].format(c=a.caption) if a.caption else t["image_blank"]
    if a.kind == "voice":                    # TA 的语音（10-03）：正文是转写，这里只给〔语音 23 秒：…〕那行
        return a.caption or t["voice_blank"]
    body = a.text if len(a.text) <= TEXT_MAX_CHARS else a.text[:TEXT_MAX_CHARS] + "\n" + t["cut"]
    return t["file"].format(n=a.name, t=body)


async def decorate(pool, msgs: list[StoredMsg], lang: str) -> list[StoredMsg]:
    """历史里 TA 那句带了附件的，在后面接上〔图片：描述〕〔文件：字〕——它看历史时知道当时发了什么。"""
    got = await for_messages(pool, [m.id for m in msgs if m.role == "user"])
    return [replace(m, text="\n".join([m.text, *(note(a, lang) for a in got[m.id])]).strip()) if m.id in got else m
            for m in msgs]


async def wipe_from(pool, conversation: UUID, from_message: int) -> None:
    """倒回：从这条起被删掉的消息带的附件，文件一起删。"""
    rows = await pool.fetch("DELETE FROM attachments WHERE conversation_id = $1 AND message_id >= $2 RETURNING path",
                            conversation, from_message)
    for r in rows:
        Path(r["path"]).unlink(missing_ok=True)


async def wipe(pool, where: str, value) -> None:
    """删窗口 / 删号时连文件一起删。where 是 conversation_id 或 account_id。"""
    assert where in ("conversation_id", "account_id")
    rows = await pool.fetch(f"DELETE FROM attachments WHERE {where} = $1 RETURNING path", value)
    for r in rows:
        Path(r["path"]).unlink(missing_ok=True)
