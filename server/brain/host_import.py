"""Mele Host 搬家（10-04 第三步）：Lite 手机里的东西一次性整包搬上 Host。

第一版搬核心：我的设定、模型钥匙（原文进来，用 Host 的主密钥加密存）、联系人（人设、设置、头像、用哪把钥匙）、
每个窗口的聊天（按原来的时间）。房间（日记、相册、书架……）后面一样样加，包里多出来的键先不认。
- 联系人和窗口用手机里的 UUID：同一个包再搬一次不会重复（已经有的跳过）。
- Host 配对时送的那个空 Lumi（一句都没聊过）在搬进来的联系人面前让位。
- 设置过一遍 Settings（不认识的键丢掉、不合法的报错），跟 Host 自己存的一样干净。
- 房间（10-05 第一批）：包里 rooms = {kind: [手机条目]}，手机本来就照服务器的形状存。搬过的记在 host_imported，
  再搬只补新的；条目的联系人 Host 上没有就跳过。里程碑 10-05 也上了服务器，一起搬。
- 带文件的房间（10-05 第二批：相册、表情包、书架、饮食、朋友圈、塔罗）：文件不塞进包里——手机先问 needed() 缺哪些指纹，
  一个个 PUT 上来 stage() 进暂存，包里的条目只写指纹；文件没到的条目这次跳过（不记账），下次再搬补上。搬完清空暂存。
  搬来的朋友圈不排联系人来刷；没解完的塔罗记成 failed（不在 Host 上偷偷花钱）。"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import shutil
from datetime import datetime
from pathlib import Path
from uuid import UUID, uuid4

from . import accounts, archive, attachments, auth, avatars, hidden
from .settings import Settings

VERSION = 1
STAGING = "import-staging"
STAGE_MAX = 25 * 1024 * 1024          # 一个文件最多 25MB（书 20MB、照片 10MB 都装得下）
TEXT_KINDS = ("diary", "drawer", "dates", "todos", "wallet", "people", "lore", "favorites", "milestones")
FILE_KINDS = ("album", "stickers", "books", "book-marks", "book-reading", "food", "food-covers", "moments",
              "moment-profiles", "tarot")   # 顺序要紧：书在划线前，饮食在封面前


class ImportError_(Exception):
    pass


def _when(v, fallback: datetime) -> datetime:
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return fallback


async def _empty_defaults(pool, acc: UUID) -> list[UUID]:
    """一句都没聊过的联系人（配对时送的 Lumi）"""
    rows = await pool.fetch(
        """SELECT c.id FROM companions c WHERE c.account_id = $1 AND NOT EXISTS (
             SELECT 1 FROM conversations v JOIN chat_messages m ON m.user_id = v.id WHERE v.companion_id = c.id)""", acc)
    return [r["id"] for r in rows]


async def run(pool, box: auth.KeyBox, acc: UUID, bundle: dict, *, files_dir: Path, now: datetime, embedder=None) -> dict:
    if bundle.get("version") != VERSION:
        raise ImportError_(f"搬家包的版本对不上（{bundle.get('version')}），把 App 和 Host 都更新到最新")
    counts = {"companions": 0, "conversations": 0, "messages": 0, "keys": 0}

    key_ids: dict[str, UUID] = {}
    for k in bundle.get("keys") or []:
        try:
            key_ids[str(k.get("local_id"))] = await auth.add_key(
                pool, box, acc, provider=str(k.get("provider") or ""), api_key=str(k.get("api_key") or ""),
                chat_model=str(k.get("chat_model") or ""), base_url=k.get("base_url") or None)
            counts["keys"] += 1
        except auth.AuthError:
            continue                                   # 手机里一把坏 key 不挡整个搬家

    comps = bundle.get("companions") or []
    existing = set(await accounts.list_companions(pool, acc))
    empty = [c for c in await _empty_defaults(pool, acc)] if comps else []

    for c in comps:
        try:
            cid = UUID(str(c.get("id")))
        except ValueError:
            continue
        if cid in existing:
            continue
        await accounts.create_companion(pool, acc, cid)
        counts["companions"] += 1
        await archive.save_persona(pool, cid, dict(c.get("persona") or {}), now=now)
        try:
            settings = Settings.from_dict(c.get("settings") or {}).to_dict()
        except (TypeError, ValueError):
            settings = Settings().to_dict()
        await archive.save_settings(pool, cid, settings, now=now)
        if (kid := key_ids.get(str(c.get("key_local_id")))) is not None:
            await auth.use_key(pool, acc, cid, kid)
        if c.get("avatar_b64"):
            try:
                avatars.save(files_dir, cid, base64.b64decode(c["avatar_b64"]))
                await pool.execute("UPDATE companions SET avatar_ver = avatar_ver + 1 WHERE id = $1", cid)
            except (avatars.AvatarError, binascii.Error, ValueError):
                pass
        for v in c.get("conversations") or []:
            try:
                vid = UUID(str(v.get("id")))
            except ValueError:
                continue
            await accounts.new_conversation(pool, acc, cid, conversation_id=vid)
            counts["conversations"] += 1
            last = now
            for m in v.get("messages") or []:
                text = str(m.get("text") or "")
                role = m.get("role")
                if role not in ("user", "assistant") or not text.strip():
                    continue
                last = _when(m.get("at"), now)
                await archive.add_message(pool, vid, role, text, thinking=str(m.get("thinking") or ""),
                                          thinking_ms=m.get("thinking_ms") if isinstance(m.get("thinking_ms"), int) else None,
                                          now=last)
                counts["messages"] += 1
            await pool.execute("UPDATE conversations SET last_at = $2 WHERE id = $1", vid, last)

    if counts["companions"]:                           # 搬进来了才让位（不然最后一个联系人不能删）
        for cid in empty:
            await accounts.delete_companion(pool, acc, cid)

    if isinstance(bundle.get("profile"), dict):
        try:
            await accounts.save_profile(pool, acc, bundle["profile"])
        except (TypeError, ValueError):
            pass
    if isinstance(bundle.get("rooms"), dict):
        counts["rooms"] = await _rooms(pool, acc, bundle["rooms"], now=now, embedder=embedder, files_dir=files_dir)
    shutil.rmtree(files_dir / STAGING, ignore_errors=True)
    return counts


# ── 带文件的房间：先传文件 ──

def _shas(kind: str, it: dict) -> list[str]:
    """这一条要用到的文件指纹"""
    if kind in ("album", "stickers"):
        out = [it.get("sha")]
    elif kind == "books":
        out = [it.get("text_sha"), it.get("cover_sha")]
    elif kind == "food":
        out = list((it.get("photo_shas") or {}).values())
    elif kind == "moments":
        out = list(it.get("image_shas") or [])
    elif kind == "moment-profiles":
        out = [it.get("cover_sha")]
    else:
        out = []
    return [str(x) for x in out if x]


def wanted(rooms: dict, done: set | None = None) -> list[str]:
    done = done or set()
    out: dict[str, None] = {}
    for kind in FILE_KINDS:
        for it in rooms.get(kind) or []:
            if isinstance(it, dict) and it.get("id") is not None and (kind, str(it["id"])) not in done:
                out.update(dict.fromkeys(_shas(kind, it)))
    return list(out)


def _staged(files_dir: Path, sha: str) -> Path:
    return files_dir / STAGING / sha


async def needed(pool, acc: UUID, files_dir: Path, rooms: dict) -> list[str]:
    """包里这些条目还缺哪些文件（搬过的条目不要、已经传上来的不要）"""
    done = {(r["kind"], r["local_id"]) for r in
            await pool.fetch("SELECT kind, local_id FROM host_imported WHERE account_id = $1", acc)}
    return [h for h in wanted(rooms, done) if not _staged(files_dir, h).exists()]


def stage(files_dir: Path, sha: str, data: bytes) -> None:
    if len(sha) != 64 or not all(c in "0123456789abcdef" for c in sha):
        raise ImportError_("指纹不对")
    if len(data) > STAGE_MAX:
        raise ImportError_("文件太大了（最多 25MB）")
    if hashlib.sha256(data).hexdigest() != sha:
        raise ImportError_("文件传坏了，指纹对不上，再搬一次")
    d = files_dir / STAGING
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / f".{sha}.part"
    tmp.write_bytes(data)
    tmp.replace(d / sha)


def _day(v):
    from datetime import date
    try:
        return date.fromisoformat(str(v)[:10])
    except ValueError:
        return None


def _uuid(v) -> UUID | None:
    try:
        return UUID(str(v))
    except ValueError:
        return None


async def _rooms(pool, acc: UUID, rooms: dict, *, now: datetime, embedder, files_dir: Path) -> dict:
    """一个房间一个房间翻译。返回 {kind: 这次搬了几条}（没搬的房间不出现）。"""
    mine = {c for c in await accounts.list_companions(pool, acc)}
    rows = await pool.fetch("SELECT kind, local_id, host_id FROM host_imported WHERE account_id = $1", acc)
    done = {(r["kind"], r["local_id"]) for r in rows}
    ids: dict[str, dict[str, str]] = {}               # 搬过的条目在 Host 上的编号：{kind: {手机编号: Host 编号}}
    for r in rows:
        if r["host_id"]:
            ids.setdefault(r["kind"], {})[r["local_id"]] = r["host_id"]
    moved: dict[str, int] = {}

    async def mark(kind: str, local_id, host_id=None) -> None:
        await pool.execute("INSERT INTO host_imported (account_id, kind, local_id, host_id) VALUES ($1, $2, $3, $4) "
                           "ON CONFLICT DO NOTHING", acc, kind, str(local_id), None if host_id is None else str(host_id))
        if host_id is not None:
            ids.setdefault(kind, {})[str(local_id)] = str(host_id)

    def blob(sha) -> bytes | None:
        p = _staged(files_dir, str(sha or "")) if sha else None
        return p.read_bytes() if p is not None and p.exists() else None

    def who(v) -> str | None:
        """'user' 或这里有的联系人编号"""
        if v == "user":
            return "user"
        u = _uuid(v)
        return str(u) if u in mine else None

    def comp(it, *, optional=False):
        if optional and it.get("companion_id") in (None, ""):
            return None, True
        c = _uuid(it.get("companion_id"))
        return c, c in mine

    async def one(kind: str, it: dict) -> bool:
        if kind == "diary":
            if it.get("author") != "user" or not str(it.get("body") or "").strip() or not _day(it.get("day")):
                return False
            when = _when(it.get("written_at"), now)
            await pool.execute("""INSERT INTO diaries (account_id, author, day, body, private, created_at, updated_at)
                                  VALUES ($1, 'user', $2, $3, $4, $5, $5)""",
                               acc, _day(it["day"]), str(it["body"]), bool(it.get("private")), when)
        elif kind == "drawer":
            c, ok = comp(it)
            if not ok:
                return False
            opened = it.get("opened_at")
            await pool.execute("""INSERT INTO drawer_letters (account_id, companion_id, title, content, opened_at, created_at)
                                  VALUES ($1, $2, $3, $4, $5, $6)""", acc, c, str(it.get("title") or ""),
                               str(it.get("content") or ""), _when(opened, now) if opened else None,
                               _when(it.get("written_at"), now))
        elif kind == "dates":
            c, ok = comp(it)
            if not ok or not _day(it.get("day")) or not str(it.get("title") or "").strip():
                return False
            res = it.get("resolved_at")
            await pool.execute("""INSERT INTO far_dates (account_id, companion_id, day, at_time, title, note, created_at,
                                  resolved_at, result) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)""",
                               acc, c, _day(it["day"]), str(it.get("time") or ""), str(it["title"]), str(it.get("note") or ""),
                               now, _when(res, now) if res else None, str(it.get("result") or ""))
        elif kind == "todos":
            c, ok = comp(it)
            if not ok or not str(it.get("what") or "").strip():
                return False
            created = _when(it.get("created_at"), now)
            await pool.execute("""INSERT INTO todos (account_id, companion_id, what, shape, spec, done_on, created_by,
                                  created_at, updated_at) VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $8)""",
                               acc, c, str(it["what"]), it.get("shape") or None, json.dumps(it.get("spec") or {}),
                               _day(it.get("done_on")) if it.get("done_on") else None,
                               "ai" if it.get("created_by") == "ai" else "user", created)
        elif kind == "wallet":
            if not isinstance(it.get("amount"), int) or not _day(it.get("day")):
                return False
            await pool.execute("""INSERT INTO wallet_entries (account_id, kind, amount, category, note, day, author, created_at)
                                  VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
                               acc, "in" if it.get("kind") == "in" else "out", it["amount"], str(it.get("category") or ""),
                               str(it.get("note") or ""), _day(it["day"]), "ai" if it.get("author") == "ai" else "user",
                               _when(it.get("created_at"), now))
        elif kind == "people":
            import memory as M
            if embedder is None or not str(it.get("name") or "").strip():
                return False
            p = await M.upsert_person(pool, embedder, acc, str(it["name"]), relation=it.get("relation") or None,
                                      facts=it.get("facts") or None, impression=it.get("impression") or None,
                                      aliases=it.get("aliases") or [], by="ai" if it.get("created_by") == "ai" else "user",
                                      now=now)
            hide = [u for u in (_uuid(x) for x in it.get("hidden_from") or []) if u in mine]
            if hide:
                await hidden.set_hidden(pool, acc, p.id, hide)
        elif kind == "lore":
            c, ok = comp(it, optional=True)
            if not ok or not str(it.get("content") or "").strip():
                return False
            await pool.execute("""INSERT INTO lore (account_id, companion_id, name, keywords, content, created_by, enabled,
                                  constant, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9)""",
                               acc, c, str(it.get("name") or ""), [str(k) for k in it.get("keywords") or []],
                               str(it["content"]), "ai" if it.get("created_by") == "ai" else "user",
                               it.get("enabled", True) is not False, bool(it.get("constant")), now)
        elif kind == "favorites":
            c, ok = comp(it)
            conv = _uuid(it.get("conversation_id"))
            if not ok or conv is None:
                return False
            said = _when(it.get("said_at"), now)
            mid = await pool.fetchval(
                """SELECT m.id FROM chat_messages m JOIN conversations v ON v.id = m.user_id
                   WHERE m.user_id = $1 AND v.companion_id = $2 AND m.created_at = $3 AND m.role = $4 ORDER BY m.id LIMIT 1""",
                conv, c, said, "user" if it.get("mine") else "assistant")
            if mid is None:
                return False
            await pool.execute("""INSERT INTO favorites (account_id, companion_id, conversation_id, message_id, slot, mine, text,
                                  files, group_id, said_at, saved_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11)""",
                               acc, c, conv, mid, int(it.get("slot") or 0), bool(it.get("mine")), str(it.get("text") or ""),
                               json.dumps(it.get("files") or []), _uuid(it.get("group_id")) if it.get("group_id") else None,
                               said, _when(it.get("saved_at"), now))
        elif kind == "milestones":
            c, ok = comp(it)
            title = " ".join(str(it.get("title") or "").split())[:60]
            if not ok or not title:
                return False
            await pool.execute("INSERT INTO milestones (account_id, companion_id, title, created_at) VALUES ($1, $2, $3, $4)",
                               acc, c, title, _when(it.get("at"), now))
        else:
            return await with_files(kind, it)
        return True

    async def with_files(kind: str, it: dict):
        """第二批。返回 False = 这次不搬（下次再来）；True / Host 编号 = 搬好了"""
        from . import album, books, moments, stickers
        if kind == "album":
            c, ok = comp(it)
            data = blob(it.get("sha"))
            if not ok or data is None:
                return False
            try:
                img = attachments._image(data)
            except attachments.AttachmentError:
                return True                                # 坏图不再要
            dest = album.album_dir(files_dir) / f"{uuid4()}.jpg"
            texts = {k: str(it.get(k) or "")[:n] for k, n in album.LIMITS.items()}
            pid = await pool.fetchval(
                """INSERT INTO album_photos (account_id, companion_id, sha, path, source, taken_at, caption, felt, why, thoughts,
                                              note, batch, starred, secret, look_status, created_at)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $6)
                   ON CONFLICT (account_id, companion_id, sha) DO NOTHING RETURNING id""",
                acc, c, hashlib.sha256(data).hexdigest(), str(dest), "mine" if it.get("source") == "user" else "chat",
                _when(it.get("taken_at"), now), texts.get("caption", ""), texts.get("felt", ""), texts.get("why", ""),
                texts.get("thoughts", ""), str(it.get("note") or "")[:1000], str(it.get("batch") or ""), bool(it.get("starred")),
                bool(it.get("secret")), "done" if any(texts.get(k) for k in ("caption", "felt", "thoughts")) else "")
            if pid is not None:
                dest.write_bytes(img)
            return True
        if kind == "stickers":
            data = blob(it.get("sha"))
            if data is None or embedder is None:
                return False
            try:
                st, new = await stickers.add(pool, embedder, files_dir, acc, data=data, name=str(it.get("name") or ""),
                                             caption=str(it.get("caption") or ""))
            except stickers.StickerError:
                return False
            if new:
                only = [u for u in (_uuid(x) for x in it.get("only_for") or []) if u in mine]
                await pool.execute("UPDATE stickers SET only_for = $2, use_count = $3, created_at = $4 WHERE id = $1", st.id,
                                   only, int(it.get("use_count") or 0), _when(it.get("created_at"), now))
            return str(st.id)
        if kind == "books":
            data = blob(it.get("text_sha"))
            if data is None:
                return False
            title = str(it.get("title") or "未命名")
            try:
                b = await books.add(pool, files_dir, acc, name=f"{title}.txt", data=data, title=title,
                                    now=_when(it.get("created_at"), now))
            except books.BookError:
                return True
            read = it.get("read_at")
            await pool.execute("""UPDATE books SET at_chapter = $2, at_page = $3, page_count = $4, furthest = $5, read_at = $6
                                  WHERE id = $1""", b.id, int(it.get("at_chapter") or 0), int(it.get("at_page") or 0),
                               int(it.get("page_count") or 0), int(it.get("furthest") or 0), _when(read, now) if read else None)
            if (cover := blob(it.get("cover_sha"))) is not None:
                try:
                    await books.set_cover(pool, acc, b.id, files_dir, cover)
                except attachments.AttachmentError:
                    pass
            return str(b.id)
        if kind == "book-marks":
            bid = ids.get("books", {}).get(str(it.get("book_id")))
            author = who(it.get("author"))
            if bid is None or author is None:
                return False
            c = _uuid(it.get("companion_id")) if it.get("companion_id") else None
            parent = it.get("parent_id")
            pid = ids.get("book-marks", {}).get(str(parent)) if parent is not None else None
            if parent is not None and pid is None:
                return False
            mid = await pool.fetchval(
                """INSERT INTO book_marks (account_id, book_id, chapter, quote, note, pos, author, companion_id, parent_id, created_at)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id""",
                acc, int(bid), int(it.get("chapter") or 0), str(it.get("quote") or ""), str(it.get("note") or ""),
                int(it.get("pos") if isinstance(it.get("pos"), int) else -1), author, c if c in mine else None,
                int(pid) if pid else None, _when(it.get("created_at"), now))
            return str(mid)
        if kind == "book-reading":
            bid = ids.get("books", {}).get(str(it.get("book_id")))
            if bid is None or not _day(it.get("day")):
                return False
            await pool.execute("""INSERT INTO book_reading (account_id, book_id, day, seconds) VALUES ($1, $2, $3, $4)
                                  ON CONFLICT (account_id, book_id, day) DO UPDATE SET seconds = GREATEST(book_reading.seconds,
                                  EXCLUDED.seconds)""", acc, int(bid), _day(it["day"]), int(it.get("seconds") or 0))
            return True
        if kind == "food":
            if not str(it.get("text") or "").strip() or not _day(it.get("date")):
                return False
            shas = it.get("photo_shas") or {}
            photos: list[UUID] = []
            for p in it.get("photo_ids") or []:
                if (have := ids.get("food-photo", {}).get(str(p))) is not None:
                    photos.append(UUID(have))
                    continue
                data = blob(shas.get(str(p)))
                if data is None:
                    return False
                try:
                    att = await attachments.save(pool, files_dir, account=acc, conversation=None, name="photo.jpg",
                                                 mime="image/jpeg", data=data)
                except attachments.AttachmentError:
                    continue
                await mark("food-photo", p, att.id)
                photos.append(att.id)
            def num(k):
                v = it.get(k)
                return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
            created = _when(it.get("created_at"), now)
            eid = await pool.fetchval(
                """INSERT INTO food_entries (account_id, day, meal, text, detail, portion, kcal, protein, carbs, fat, status, note,
                                              source, ext_id, created_at, updated_at)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
                   ON CONFLICT DO NOTHING RETURNING id""",
                acc, _day(it["date"]), str(it.get("meal") or ""), str(it["text"]), str(it.get("detail") or ""),
                str(it.get("portion") or ""), num("kcal"), num("protein"), num("carbs"), num("fat"),
                str(it.get("status") or "manual"), str(it.get("note") or ""),
                it.get("source") if it.get("source") in ("app", "lumi", "watch") else "app", it.get("ext_id") or None,
                created, _when(it.get("updated_at"), created))
            if eid is None:
                return True                                # 手表那条 Host 上已经有了
            for i, pid in enumerate(dict.fromkeys(photos)):
                await pool.execute("INSERT INTO food_photos (entry_id, attachment_id, pos) VALUES ($1, $2, $3)", eid, pid, i)
            return str(eid)
        if kind == "food-covers":
            att = ids.get("food-photo", {}).get(str(it.get("photo_id")))
            if att is None or not _day(it.get("day")):
                return False
            await pool.execute("INSERT INTO food_covers (account_id, day, attachment_id) VALUES ($1, $2, $3) "
                               "ON CONFLICT (account_id, day) DO NOTHING", acc, _day(it["day"]), UUID(att))
            return True
        if kind == "moments":
            author = who(it.get("author"))
            if author is None:
                return False
            imgs = []
            for sha in it.get("image_shas") or []:
                data = blob(sha)
                if data is None:
                    return False
                try:
                    imgs.append(moments.save_image(files_dir, data))
                except attachments.AttachmentError:
                    continue
            mid = await pool.fetchval("""INSERT INTO moments (account_id, author, content, images, created_at)
                                         VALUES ($1, $2, $3, $4::jsonb, $5) RETURNING id""",
                                      acc, author, str(it.get("content") or "")[:moments.CONTENT_MAX], json.dumps(imgs),
                                      _when(it.get("created_at"), now))
            for l in it.get("likes") or []:
                if (w := who(l.get("who"))) is not None:
                    await pool.execute("INSERT INTO moment_likes (moment_id, who, created_at) VALUES ($1, $2, $3) "
                                       "ON CONFLICT DO NOTHING", mid, w, _when(l.get("at"), now))
            back: dict[str, int] = {}
            for cm in sorted(it.get("comments") or [], key=lambda x: x.get("id") or 0):
                if (w := who(cm.get("author"))) is None or not str(cm.get("content") or "").strip():
                    continue
                back[str(cm.get("id"))] = await pool.fetchval(
                    """INSERT INTO moment_comments (moment_id, author, content, reply_to, created_at)
                       VALUES ($1, $2, $3, $4, $5) RETURNING id""", mid, w, str(cm["content"]),
                    back.get(str(cm.get("reply_to"))), _when(cm.get("created_at"), now))
            return str(mid)
        if kind == "moment-profiles":
            w = who(it.get("who"))
            if w is None:
                return False
            if it.get("cover_sha"):
                if (data := blob(it["cover_sha"])) is None:
                    return False
                await moments.set_cover(pool, files_dir, acc, w, data)
            await moments.set_signature(pool, acc, w, str(it.get("signature") or ""))
            return True
        if kind == "tarot":
            c, ok = comp(it, optional=True)
            route = _uuid(it.get("route_from")) if it.get("route_from") else None
            if not ok or not str(it.get("question") or "").strip():
                return False
            status = it.get("status") if it.get("status") in ("done", "failed") else "failed"
            fus = [dict(f, status=f.get("status") if f.get("status") in ("done", "failed") else "failed")
                   for f in it.get("followups") or [] if isinstance(f, dict)]
            await pool.execute(
                """INSERT INTO tarot_readings (account_id, companion_id, route_from, asker, drawn_by, question, spread, cards, seed,
                                                mode, interpretation, status, tries, told, followups, created_at)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11, $12, $13, TRUE, $14::jsonb, $15)""",
                acc, c, route if route in mine else None, "contact" if it.get("asker") == "contact" else "user",
                "contact" if it.get("drawn_by") == "contact" else "user", str(it["question"]), str(it.get("spread") or ""),
                json.dumps(it.get("cards") or [], ensure_ascii=False), str(it.get("seed") or ""), str(it.get("mode") or "hand"),
                str(it.get("interpretation") or ""), status, int(it.get("tries") or 0), json.dumps(fus, ensure_ascii=False),
                _when(it.get("created_at"), now))
            return True
        return False

    for kind in TEXT_KINDS + FILE_KINDS:
        for it in rooms.get(kind) or []:
            if not isinstance(it, dict) or it.get("id") is None or (kind, str(it["id"])) in done:
                continue
            if got := await one(kind, it):
                await mark(kind, it["id"], got if isinstance(got, str) else None)
                moved[kind] = moved.get(kind, 0) + 1
    return moved
