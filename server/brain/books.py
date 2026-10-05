"""书架 · 一起读书（10-02，照之前自用的 App共读书房；设计 docs/specs/2026-10-02-bookshelf-design.md）。

- TA 导入 txt（UTF-8 / GB18030），按「第 X 章 / Chapter X / 卷」切章；切不出来每 3000 字一段。正文放文件，章的位置放表里。
- 页边：划线（只有 quote）、批注（quote + note）、往来（parent_id 挂在线头底下）。author = 'user' 或联系人编号。
- 「划线说两句」：TA 那句带着 book_mark_id 发进聊天，线头挂在窗口上（book_threads），它接下来半小时的回话抄一份进页边。
- 它知道 TA 在读哪（〔在读〕，3 分钟内翻过页才有）；工具 book 能翻到 TA 那一页、在页边留一笔（每天最多 3 笔），
  只能翻到 TA 读到过的最远那章，不剧透。"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from uuid import UUID

MAX_BYTES = 20 * 1024 * 1024
CHUNK = 3000
READING_FRESH = timedelta(minutes=3)
THREAD_TTL = timedelta(minutes=30)
MARKS_PER_DAY = 3
PAGE_CHARS = 1500

_HEAD = re.compile(r"^\s*(第[零〇一二三四五六七八九十百千万两0-9]{1,8}[章节回卷部集篇][^\n]{0,40}"
                   r"|(?:Chapter|CHAPTER)\s+[0-9IVXLCivxlc]+\b[^\n]{0,60}"
                   r"|卷[零〇一二三四五六七八九十0-9]{1,4}[^\n]{0,30}"
                   r"|序[章言]?|楔子|尾声|后记|番外[^\n]{0,30})\s*$", re.M)


class BookError(ValueError):
    pass


@dataclass
class Book:
    id: int
    title: str
    path: str
    chapters: list
    cover_path: str
    at_chapter: int
    at_page: int
    page_count: int
    furthest: int
    read_at: datetime | None
    created_at: datetime

    def public(self, today_seconds: int = 0, marks: int = 0) -> dict:
        n = len(self.chapters)
        progress = (self.at_chapter + (self.at_page + 1) / self.page_count if self.page_count else self.at_chapter) / n if n else 0
        return {"id": self.id, "title": self.title, "chapters": n, "at_chapter": self.at_chapter, "at_page": self.at_page,
                "page_count": self.page_count, "progress": round(min(1.0, progress), 4), "has_cover": bool(self.cover_path),
                "read_at": self.read_at.isoformat() if self.read_at else None, "today_minutes": today_seconds // 60,
                "marks": marks, "created_at": self.created_at.isoformat()}


_COLS = "id, title, path, chapters, cover_path, at_chapter, at_page, page_count, furthest, read_at, created_at"


def _row(r) -> Book:
    d = dict(r)
    if isinstance(d["chapters"], str):
        d["chapters"] = json.loads(d["chapters"])
    return Book(**d)


def decode(data: bytes) -> str:
    for enc in ("utf-8-sig", "gb18030"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    raise BookError("这个文件读不出来（只认 UTF-8 和 GBK 的 txt）")


def split(text: str) -> list[list]:
    """[[章名, 起, 止]]。找得到两个以上章节标题就按标题切；否则每 CHUNK 字一段（尽量断在换行）。"""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    heads = list(_HEAD.finditer(text))
    out: list[list] = []
    if len(heads) >= 2:
        if text[:heads[0].start()].strip():
            out.append(["开头", 0, heads[0].start()])
        for i, h in enumerate(heads):
            end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
            out.append([h.group(0).strip()[:60], h.start(), end])
        return out
    pos, n = 0, 1
    while pos < len(text):
        end = min(len(text), pos + CHUNK)
        if end < len(text):
            cut = text.rfind("\n", pos + CHUNK // 2, end)
            end = cut + 1 if cut > 0 else end
        out.append([f"第 {n} 段", pos, end])
        pos, n = end, n + 1
    return out or [["全文", 0, 0]]


def _norm(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


async def add(pool, files_dir: Path, account: UUID, *, name: str, data: bytes, title: str = "",
              now: datetime) -> Book:
    if len(data) > MAX_BYTES:
        raise BookError("书太大了（最多 20MB）")
    if not name.lower().endswith((".txt", ".text")) and not title:
        raise BookError("先只认 txt")
    text = _norm(decode(data)).strip("﻿")
    if not text.strip():
        raise BookError("这本书是空的")
    d = files_dir / "books"
    d.mkdir(parents=True, exist_ok=True)
    title = (title or Path(name).stem or "未命名").strip()[:100]
    r = await pool.fetchrow(f"INSERT INTO books (account_id, title, path, chapters, created_at) VALUES ($1, $2, '', $3::jsonb, $4) "
                            f"RETURNING {_COLS}", account, title, json.dumps(split(text), ensure_ascii=False), now)
    path = d / f"{r['id']}.txt"
    path.write_text(text, encoding="utf-8")
    await pool.execute("UPDATE books SET path = $2 WHERE id = $1", r["id"], str(path))
    return await get(pool, account, r["id"])


async def get(pool, account: UUID, bid: int) -> Book | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM books WHERE account_id = $1 AND id = $2", account, bid)
    return _row(r) if r else None


async def list_all(pool, account: UUID, today: date) -> list[dict]:
    rows = await pool.fetch(
        f"""SELECT {', '.join('b.' + c.strip() for c in _COLS.split(','))},
                   COALESCE((SELECT seconds FROM book_reading WHERE book_id = b.id AND day = $2), 0) AS today,
                   (SELECT count(*) FROM book_marks WHERE book_id = b.id) AS marks
            FROM books b WHERE b.account_id = $1 ORDER BY COALESCE(b.read_at, b.created_at) DESC""", account, today)
    out = []
    for r in rows:
        d = dict(r)
        today_s, marks = d.pop("today"), d.pop("marks")
        out.append(_row(d).public(today_s, marks))
    return out


def chapter_text(book: Book, i: int) -> str:
    if not 0 <= i < len(book.chapters):
        raise BookError("没有这一章")
    _, start, end = book.chapters[i]
    with open(book.path, encoding="utf-8") as fh:
        return fh.read()[start:end]


async def rename(pool, account: UUID, bid: int, title: str) -> Book | None:
    title = title.strip()[:100]
    if not title:
        raise BookError("书名不能空着")
    r = await pool.fetchrow(f"UPDATE books SET title = $3 WHERE account_id = $1 AND id = $2 RETURNING {_COLS}",
                            account, bid, title)
    return _row(r) if r else None


async def set_cover(pool, account: UUID, bid: int, files_dir: Path, data: bytes) -> bool:
    from . import attachments
    book = await get(pool, account, bid)
    if book is None:
        return False
    blob = attachments._image(data)
    path = files_dir / "books" / f"{bid}.cover.jpg"
    path.write_bytes(blob)
    await pool.execute("UPDATE books SET cover_path = $2 WHERE id = $1", bid, str(path))
    return True


async def delete(pool, account: UUID, bid: int) -> bool:
    r = await pool.fetchrow("DELETE FROM books WHERE account_id = $1 AND id = $2 RETURNING path, cover_path", account, bid)
    if r is None:
        return False
    for p in (r["path"], r["cover_path"]):
        if p:
            Path(p).unlink(missing_ok=True)
    return True


async def report(pool, account: UUID, bid: int, *, chapter: int, page: int, page_count: int, seconds: int,
                 today: date, now: datetime) -> bool:
    """阅读器报一声：翻页（seconds=0）或开着的每分钟（seconds=60）。"""
    book = await get(pool, account, bid)
    if book is None:
        return False
    chapter = max(0, min(chapter, len(book.chapters) - 1))
    await pool.execute("""UPDATE books SET at_chapter = $2, at_page = $3, page_count = $4, furthest = GREATEST(furthest, $2),
                          read_at = $5 WHERE id = $1""", bid, chapter, max(0, page), max(0, page_count), now)
    if seconds > 0:
        await pool.execute("""INSERT INTO book_reading (account_id, book_id, day, seconds) VALUES ($1, $2, $3, $4)
                              ON CONFLICT (account_id, book_id, day) DO UPDATE SET seconds = book_reading.seconds + $4""",
                           account, bid, today, min(seconds, 600))
    return True


# ── 页边 ──

def _mark(r) -> dict:
    return {"id": r["id"], "book_id": r["book_id"], "chapter": r["chapter"], "quote": r["quote"], "note": r["note"],
            "pos": r["pos"], "author": r["author"], "companion_id": str(r["companion_id"]) if r["companion_id"] else None,
            "parent_id": r["parent_id"], "created_at": r["created_at"].isoformat()}


_MCOLS = "id, book_id, chapter, quote, note, pos, author, companion_id, parent_id, created_at"


async def marks(pool, account: UUID, bid: int, chapter: int | None = None) -> list[dict]:
    if chapter is None:
        rows = await pool.fetch(f"SELECT {_MCOLS} FROM book_marks WHERE account_id = $1 AND book_id = $2 ORDER BY id",
                                account, bid)
    else:
        rows = await pool.fetch(f"SELECT {_MCOLS} FROM book_marks WHERE account_id = $1 AND book_id = $2 AND chapter = $3 "
                                "ORDER BY id", account, bid, chapter)
    return [_mark(r) for r in rows]


async def add_mark(pool, account: UUID, bid: int, *, chapter: int, quote: str, note: str, author: str,
                   pos: int = -1, companion: UUID | None = None, parent: int | None = None, now: datetime) -> dict:
    book = await get(pool, account, bid)
    if book is None:
        raise BookError("没有这本书")
    quote, note = quote.strip()[:500], note.strip()[:2000]
    if parent:
        root = await pool.fetchrow("SELECT chapter, companion_id, parent_id FROM book_marks WHERE id = $1 AND book_id = $2",
                                   parent, bid)
        if root is None:
            raise BookError("没有这道划线")
        parent = root["parent_id"] or parent
        chapter, companion = root["chapter"], companion or root["companion_id"]
    elif not quote:
        raise BookError("要划哪一句？")
    if not 0 <= chapter < len(book.chapters):
        raise BookError("没有这一章")
    if not quote and not note:
        raise BookError("写点什么吧")
    r = await pool.fetchrow(
        f"""INSERT INTO book_marks (account_id, book_id, chapter, quote, note, pos, author, companion_id, parent_id, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING {_MCOLS}""",
        account, bid, chapter, quote, note, pos, author, companion, parent, now)
    return _mark(r)


async def delete_mark(pool, account: UUID, bid: int, mid: int) -> bool:
    """TA 只能删自己写的；删的是线头就连底下的往来一起删（它的回话也跟着走）。"""
    own = await pool.fetchval("SELECT 1 FROM book_marks WHERE account_id = $1 AND book_id = $2 AND id = $3 AND author = 'user'",
                              account, bid, mid)
    if not own:
        return False
    await pool.execute("DELETE FROM book_marks WHERE book_id = $1 AND (id = $2 OR parent_id = $2)", bid, mid)
    return True


# ── 划线说两句：线头挂在窗口上 ──

async def arm_thread(pool, account: UUID, conversation: UUID, mark_id: int, now: datetime) -> bool:
    ok = await pool.fetchval("SELECT 1 FROM book_marks WHERE id = $1 AND account_id = $2", mark_id, account)
    if not ok:
        return False
    await pool.execute("""INSERT INTO book_threads (conversation_id, mark_id, armed_at) VALUES ($1, $2, $3)
                          ON CONFLICT (conversation_id) DO UPDATE SET mark_id = $2, armed_at = $3""",
                       conversation, mark_id, now)
    return True


async def disarm(pool, conversation: UUID) -> None:
    await pool.execute("DELETE FROM book_threads WHERE conversation_id = $1", conversation)


async def catch_reply(pool, account: UUID, conversation: UUID, companion: UUID, text: str, now: datetime) -> None:
    """它这一轮的回话：线头还挂着（半小时内）就抄一份进页边。"""
    r = await pool.fetchrow("""SELECT t.mark_id, t.armed_at, m.book_id FROM book_threads t JOIN book_marks m ON m.id = t.mark_id
                               WHERE t.conversation_id = $1""", conversation)
    if r is None:
        return
    if now - r["armed_at"] > THREAD_TTL:
        await disarm(pool, conversation)
        return
    if text.strip():
        await add_mark(pool, account, r["book_id"], chapter=0, quote="", note=text.strip(), author=str(companion),
                       companion=companion, parent=r["mark_id"], now=now)


# ── 它那边：〔在读〕和工具 ──

async def reading_now(pool, account: UUID, now: datetime) -> Book | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM books WHERE account_id = $1 AND read_at > $2 ORDER BY read_at DESC LIMIT 1",
                            account, now - READING_FRESH)
    return _row(r) if r else None


async def reading_line(pool, account: UUID, now: datetime, lang: str) -> str:
    b = await reading_now(pool, account, now)
    if b is None or not b.chapters:
        return ""
    ch = b.chapters[min(b.at_chapter, len(b.chapters) - 1)][0]
    page = f"，这一章第 {b.at_page + 1}/{b.page_count} 页" if b.page_count else ""
    if lang == "zh":
        return f"〔在读〕TA 正在读《{b.title}》{ch}{page}。想看 TA 这一页写了什么，用 book(action=\"page\")。"
    page = f", page {b.at_page + 1}/{b.page_count} of this chapter" if b.page_count else ""
    return f"〔Reading〕They're reading \"{b.title}\", {ch}{page}. To see this page, use book(action=\"page\")."


def page_text(book: Book, chapter: int, page: int, page_count: int) -> str:
    """手机上的一页大概在这一章的哪一段：按页码比例取，前后各带一点，最多 PAGE_CHARS 字。"""
    text = chapter_text(book, chapter)
    if not text:
        return ""
    if page_count > 0:
        mid = int(len(text) * (page + 0.5) / page_count)
    else:
        mid = PAGE_CHARS // 2
    start = max(0, mid - PAGE_CHARS // 2)
    return text[start:start + PAGE_CHARS].strip()


async def marks_today(pool, account: UUID, companion: UUID, since: datetime) -> int:
    return await pool.fetchval("SELECT count(*) FROM book_marks WHERE account_id = $1 AND author = $2 AND parent_id IS NULL "
                               "AND created_at >= $3", account, str(companion), since)


async def export(pool, account: UUID) -> list[dict]:
    out = []
    for r in await pool.fetch(f"SELECT {_COLS} FROM books WHERE account_id = $1 ORDER BY id", account):
        b = _row(r)
        out.append({"title": b.title, "chapters": len(b.chapters), "at_chapter": b.at_chapter,
                    "marks": await marks(pool, account, b.id)})
    return out
