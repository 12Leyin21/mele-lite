"""Mele Host 搬家（10-04 第三步）：Lite 手机里的东西一次性整包搬上 Host。测试数据用小满 / Mia。"""
import base64
import json
import io
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

import pytest
from cryptography.fernet import Fernet

from brain import accounts, archive, auth, host_import
from memory.embed import FakeEmbedder

NOW = datetime(2026, 10, 5, 1, 0, tzinfo=timezone.utc)
CID = "6b1f0c3e-1111-4a2b-9c3d-000000000001"
CONV = "6b1f0c3e-2222-4a2b-9c3d-000000000002"
def _png() -> str:
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (4, 4), (200, 120, 160)).save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode()


PNG = _png()


def bundle(**over):
    b = {
        "version": 1,
        "profile": {"name": "小满", "pronoun": "she"},
        "keys": [{"local_id": "k1", "provider": "deepseek", "chat_model": "deepseek-flash", "api_key": "sk-test-0000000001234"}],
        "companions": [{
            "id": CID, "persona": {"name": "Mia", "about": "温柔"}, "settings": {"voice_mode": "often", "not_a_setting": 1},
            "key_local_id": "k1", "avatar_b64": PNG,
            "conversations": [{"id": CONV, "messages": [
                {"role": "user", "text": "早", "at": "2026-10-01T00:00:00Z"},
                {"role": "assistant", "text": "早呀", "thinking": "她起得早", "at": "2026-10-01T00:00:05Z"},
            ]}],
        }],
    }
    b.update(over)
    return b


@pytest.fixture
def box():
    return auth.KeyBox(Fernet.generate_key())


async def test_import_moves_core(pool, box, tmp_path):
    acc = await auth.new_account(pool)                       # 配对时送的那个空 Lumi
    got = await host_import.run(pool, box, acc, bundle(), files_dir=tmp_path, now=NOW)
    assert got == {"companions": 1, "conversations": 1, "messages": 2, "keys": 1}
    comps = await accounts.list_companions(pool, acc)
    assert [str(c) for c in comps] == [CID]                 # 空的那个 Lumi 让位
    assert (await archive.get_persona(pool, comps[0]))["name"] == "Mia"
    s = await archive.get_settings(pool, comps[0])
    assert s["voice_mode"] == "often" and "not_a_setting" not in s
    msgs = await pool.fetch("SELECT role, text, thinking, created_at FROM chat_messages WHERE user_id = $1 ORDER BY id", UUID(CONV))
    assert [(m["role"], m["text"]) for m in msgs] == [("user", "早"), ("assistant", "早呀")]
    assert msgs[1]["thinking"] == "她起得早"
    assert msgs[0]["created_at"] == datetime(2026, 10, 1, tzinfo=timezone.utc)   # 按原来的时间
    key = await pool.fetchrow("SELECT provider, secret, last4 FROM keyring WHERE account_id = $1", acc)
    assert key["provider"] == "deepseek" and key["last4"] == "1234" and box.unlock(key["secret"]) == "sk-test-0000000001234"
    bound = await pool.fetchval("SELECT key_id FROM companions WHERE id = $1", comps[0])
    assert bound is not None
    assert (tmp_path / "avatars" / f"{CID}.jpg").exists()
    prof = await accounts.get_profile(pool, acc)
    assert prof["name"] == "小满"


async def test_import_keeps_companion_that_has_chats(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    lumi = (await accounts.list_companions(pool, acc))[0]
    conv = (await accounts.list_conversations(pool, acc, lumi))[0]
    await archive.add_message(pool, conv.id, "user", "在 Host 上已经聊过了", now=NOW)
    await host_import.run(pool, box, acc, bundle(), files_dir=tmp_path, now=NOW)
    assert len(await accounts.list_companions(pool, acc)) == 2


async def test_import_twice_does_not_duplicate(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    await host_import.run(pool, box, acc, bundle(), files_dir=tmp_path, now=NOW)
    again = await host_import.run(pool, box, acc, bundle(keys=[]), files_dir=tmp_path, now=NOW)
    assert again["companions"] == 0 and again["messages"] == 0
    assert await pool.fetchval("SELECT count(*) FROM chat_messages") == 2


async def test_import_rejects_unknown_version(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    with pytest.raises(host_import.ImportError_):
        await host_import.run(pool, box, acc, bundle(version=99), files_dir=tmp_path, now=NOW)


async def test_import_endpoint_host_only(pool, tmp_path):
    from tests.test_host import client, make_app
    from brain import host
    for host_mode, want in ((False, 404), (True, 200)):
        app = make_app(pool, host_mode=host_mode)
        app.state.api.cfg.files_dir = tmp_path
        acc = await host.owner(pool) or await auth.new_account(pool)
        token = await auth.new_session(pool, acc, secret="test-secret", now=NOW)
        async with client(app, token) as c:
            r = await c.post("/me/import", json=bundle(keys=[]))
        assert r.status_code == want
    assert r.json()["messages"] == 2


# ---- 第一批房间（10-05）：日记、信、远事、待办、钱包、人物卡、世界书、收藏夹 ----

def rooms():
    return {
        "diary": [{"id": 1, "author": "user", "day": "2026-10-02", "body": "今天考完了", "private": True,
                   "written_at": "2026-10-02T12:00:00Z"},
                  {"id": 2, "author": "companion", "day": "2026-10-02", "body": "TA 的日记不搬"}],
        "drawer": [{"id": 1, "companion_id": CID, "title": "给小满", "content": "一封信", "written_at": "2026-10-03T00:00:00Z",
                    "opened_at": "2026-10-03T08:00:00Z"}],
        "dates": [{"id": 1, "companion_id": CID, "day": "2026-12-21", "time": "09:00", "title": "生日", "note": ""}],
        "todos": [{"id": 1, "companion_id": CID, "what": "买猫粮", "shape": None, "spec": {}, "created_by": "user",
                   "created_at": "2026-10-03T00:00:00Z"}],
        "wallet": [{"id": 1, "kind": "out", "amount": 1250, "category": "吃饭", "note": "麻辣烫", "day": "2026-10-02",
                    "author": "user", "created_at": "2026-10-02T11:00:00Z"}],
        "people": [{"id": 1, "name": "阿杰", "aliases": ["杰哥"], "relation": "大学室友", "facts": "在悉尼做建筑师",
                    "impression": "", "created_by": "user", "hidden_from": [CID]}],
        "lore": [{"id": 1, "companion_id": None, "name": "年糕", "keywords": ["年糕"], "content": "小满的橘猫",
                  "created_by": "user", "enabled": True, "constant": False}],
        "favorites": [{"id": 1, "companion_id": CID, "conversation_id": CONV, "message_id": 77, "slot": 0, "mine": False,
                       "text": "早呀", "files": [], "group_id": None, "said_at": "2026-10-01T00:00:05Z",
                       "saved_at": "2026-10-04T00:00:00Z"},
                      {"id": 2, "companion_id": CID, "conversation_id": CONV, "message_id": 78, "slot": 0, "mine": True,
                       "text": "找不到这句", "files": [], "group_id": None, "said_at": "2020-01-01T00:00:00Z",
                       "saved_at": "2026-10-04T00:00:00Z"}],
        "dates_of_ghost": [],
    }


async def test_import_rooms_once(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    got = await host_import.run(pool, box, acc, bundle(rooms=rooms()), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert got["rooms"] == {"diary": 1, "drawer": 1, "dates": 1, "todos": 1, "wallet": 1, "people": 1, "lore": 1,
                            "favorites": 1}
    d = await pool.fetchrow("SELECT author, day::text, body, private, created_at FROM diaries WHERE account_id = $1", acc)
    assert (d["author"], d["day"], d["body"], d["private"]) == ("user", "2026-10-02", "今天考完了", True)
    assert d["created_at"] == datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
    l = await pool.fetchrow("SELECT title, opened_at FROM drawer_letters WHERE account_id = $1", acc)
    assert l["title"] == "给小满" and l["opened_at"] is not None
    assert await pool.fetchval("SELECT at_time FROM far_dates WHERE account_id = $1", acc) == "09:00"
    assert await pool.fetchval("SELECT what FROM todos WHERE account_id = $1", acc) == "买猫粮"
    w = await pool.fetchrow("SELECT kind, amount, category, day::text FROM wallet_entries WHERE account_id = $1", acc)
    assert tuple(w) == ("out", 1250, "吃饭", "2026-10-02")
    assert await pool.fetchval("SELECT count(*) FROM person_hidden WHERE companion_id = $1", UUID(CID)) == 1
    assert await pool.fetchval("SELECT keywords FROM lore WHERE account_id = $1", acc) == ["年糕"]
    f = await pool.fetchrow("SELECT message_id, text FROM favorites WHERE account_id = $1", acc)
    said = await pool.fetchval("SELECT id FROM chat_messages WHERE user_id = $1 AND role = 'assistant'", UUID(CONV))
    assert (f["message_id"], f["text"]) == (said, "早呀")                          # 编号按时间找回来


async def test_import_rooms_again_skips_what_was_moved(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    await host_import.run(pool, box, acc, bundle(rooms=rooms()), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    r2 = rooms()
    r2["wallet"].append({"id": 2, "kind": "in", "amount": 500, "category": "红包", "note": "", "day": "2026-10-04",
                         "author": "user", "created_at": "2026-10-04T00:00:00Z"})
    got = await host_import.run(pool, box, acc, bundle(rooms=r2), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert got["rooms"] == {"wallet": 1}                                       # 只补新的那一笔
    assert await pool.fetchval("SELECT count(*) FROM diaries WHERE account_id = $1", acc) == 1


async def test_import_rooms_skips_unknown_companion(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    r = rooms()
    r["drawer"][0]["companion_id"] = "6b1f0c3e-9999-4a2b-9c3d-000000000009"
    got = await host_import.run(pool, box, acc, bundle(rooms=r), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert "drawer" not in got["rooms"]


# ---- 第二批房间（10-05）：相册、表情包、书架、饮食、朋友圈、塔罗——带文件的先单独传（stage），包里只写指纹 ----

import hashlib

BOOK = "第一章 出门\n小满出门了。\n第二章 回家\n小满回家了。\n".encode()


def _jpg(color=(200, 120, 160)) -> bytes:
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, "JPEG")
    return buf.getvalue()


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


PHOTO, STICKER, MEAL, POST, COVER = _jpg(), _jpg((10, 200, 30)), _jpg((90, 90, 200)), _jpg((250, 250, 10)), _jpg((1, 2, 3))


def rooms2():
    return {
        "album": [{"id": 1, "companion_id": CID, "file": "album-1", "sha": _sha(PHOTO), "source": "user",
                   "taken_at": "2026-10-03T02:00:00Z", "caption": "海边", "felt": "晒", "thoughts": "下次还去", "note": "周末",
                   "batch": None, "starred": True, "secret": False}],
        "stickers": [{"id": 1, "sha": _sha(STICKER), "file": "sticker-1", "mime": "image/jpeg", "name": "摸摸头",
                      "caption": "一只猫在摸头", "only_for": [CID, "6b1f0c3e-9999-4a2b-9c3d-000000000009"], "use_count": 3,
                      "created_at": "2026-10-01T00:00:00Z"}],
        "books": [{"id": 1, "title": "小满的书", "file": "book-1.txt", "text_sha": _sha(BOOK), "cover_sha": _sha(COVER),
                   "at_chapter": 1, "at_page": 0, "page_count": 3, "furthest": 1, "read_at": "2026-10-04T00:00:00Z",
                   "created_at": "2026-10-02T00:00:00Z"}],
        "book-marks": [{"id": 1, "book_id": 1, "chapter": 0, "quote": "小满出门了。", "note": "", "pos": 0, "author": "user",
                        "companion_id": CID, "parent_id": None, "created_at": "2026-10-04T00:00:00Z"},
                       {"id": 2, "book_id": 1, "chapter": 0, "quote": "", "note": "去哪呀", "pos": 0, "author": CID,
                        "companion_id": CID, "parent_id": 1, "created_at": "2026-10-04T00:01:00Z"}],
        "book-reading": [{"id": "1:2026-10-04", "book_id": 1, "day": "2026-10-04", "seconds": 600}],
        "food": [{"id": 1, "meal": "午餐", "text": "麻辣烫", "detail": "", "portion": "一碗", "kcal": 650, "protein": 20,
                  "carbs": 80, "fat": 25, "date": "2026-10-02", "status": "estimated", "note": "", "source": "app",
                  "ext_id": None, "photo_ids": ["p1"], "photo_shas": {"p1": _sha(MEAL)},
                  "created_at": "2026-10-02T04:00:00Z", "updated_at": "2026-10-02T04:00:00Z"}],
        "food-covers": [{"id": "2026-10-02", "day": "2026-10-02", "photo_id": "p1"}],
        "moments": [{"id": 1, "author": "user", "content": "今天的云", "images": ["moment-a"], "image_shas": [_sha(POST)],
                     "created_at": "2026-10-03T05:00:00Z", "likes": [{"who": CID, "at": "2026-10-03T05:10:00Z"}],
                     "comments": [{"id": 1, "author": CID, "content": "好看", "reply_to": None, "created_at": "2026-10-03T05:11:00Z"},
                                  {"id": 2, "author": "user", "content": "嘿嘿", "reply_to": 1, "created_at": "2026-10-03T05:12:00Z"}]}],
        "moment-profiles": [{"id": "user", "who": "user", "signature": "小满的签名", "cover_sha": _sha(COVER)}],
        "tarot": [{"id": 1, "companion_id": CID, "route_from": CID, "asker": "user", "drawn_by": "user", "question": "考试顺利吗",
                   "spread": "one", "cards": [{"position": "现在", "card": "the-star", "reversed": False}], "seed": "s1",
                   "mode": "hand", "interpretation": "会顺利", "status": "done", "tries": 1, "told": False, "followups": [],
                   "created_at": "2026-10-03T06:00:00Z"},
                  {"id": 2, "companion_id": None, "route_from": CID, "asker": "user", "drawn_by": "user", "question": "没解完的",
                   "spread": "one", "cards": [], "seed": "s2", "mode": "auto", "interpretation": "", "status": "asked",
                   "tries": 0, "told": False, "followups": [], "created_at": "2026-10-03T07:00:00Z"}],
    }


def stage_all(tmp_path):
    for b in (PHOTO, STICKER, BOOK, MEAL, POST, COVER):
        host_import.stage(tmp_path, _sha(b), b)


async def test_import_files_needed_and_stage(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    wants = host_import.wanted(rooms2())
    assert _sha(PHOTO) in wants and _sha(BOOK) in wants and _sha(MEAL) in wants
    assert set(await host_import.needed(pool, acc, tmp_path, rooms2())) == set(wants)
    host_import.stage(tmp_path, _sha(PHOTO), PHOTO)
    assert _sha(PHOTO) not in await host_import.needed(pool, acc, tmp_path, rooms2())
    with pytest.raises(host_import.ImportError_):
        host_import.stage(tmp_path, _sha(PHOTO), b"not the same bytes")


async def test_import_rooms_with_files(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    stage_all(tmp_path)
    got = await host_import.run(pool, box, acc, bundle(rooms=rooms2()), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert got["rooms"] == {"album": 1, "stickers": 1, "books": 1, "book-marks": 2, "book-reading": 1, "food": 1,
                            "food-covers": 1, "moments": 1, "moment-profiles": 1, "tarot": 2}
    a = await pool.fetchrow("SELECT source, caption, starred, look_status, taken_at, path FROM album_photos WHERE account_id = $1", acc)
    assert (a["source"], a["caption"], a["starred"], a["look_status"]) == ("mine", "海边", True, "done")
    assert a["taken_at"] == datetime(2026, 10, 3, 2, tzinfo=timezone.utc) and Path(a["path"]).exists()
    s = await pool.fetchrow("SELECT name, only_for, use_count FROM stickers WHERE account_id = $1", acc)
    assert (s["name"], [str(x) for x in s["only_for"]], s["use_count"]) == ("摸摸头", [CID], 3)
    b = await pool.fetchrow("SELECT id, title, at_chapter, furthest, cover_path, jsonb_array_length(chapters) n FROM books "
                            "WHERE account_id = $1", acc)
    assert (b["title"], b["at_chapter"], b["furthest"], b["n"]) == ("小满的书", 1, 1, 2) and b["cover_path"]
    ms = await pool.fetch("SELECT id, author, parent_id FROM book_marks WHERE book_id = $1 ORDER BY id", b["id"])
    assert ms[0]["author"] == "user" and ms[1]["parent_id"] == ms[0]["id"]               # 往来接回原来那条
    assert await pool.fetchval("SELECT seconds FROM book_reading WHERE book_id = $1", b["id"]) == 600
    f = await pool.fetchrow("SELECT id, text, kcal, day::text FROM food_entries WHERE account_id = $1", acc)
    assert (f["text"], f["kcal"], f["day"]) == ("麻辣烫", 650, "2026-10-02")
    att = await pool.fetchval("SELECT attachment_id FROM food_photos WHERE entry_id = $1", f["id"])
    assert await pool.fetchval("SELECT attachment_id FROM food_covers WHERE account_id = $1", acc) == att
    m = await pool.fetchrow("SELECT id, content, images, created_at FROM moments WHERE account_id = $1", acc)
    assert m["content"] == "今天的云" and len(json.loads(m["images"])) == 1
    assert await pool.fetchval("SELECT count(*) FROM moment_visits WHERE moment_id = $1", m["id"]) == 0   # 搬来的不排人来刷
    cs = await pool.fetch("SELECT id, reply_to FROM moment_comments WHERE moment_id = $1 ORDER BY id", m["id"])
    assert cs[1]["reply_to"] == cs[0]["id"]
    assert await pool.fetchval("SELECT count(*) FROM moment_likes WHERE moment_id = $1", m["id"]) == 1
    p = await pool.fetchrow("SELECT signature, cover_path FROM moment_profiles WHERE account_id = $1 AND who = 'user'", acc)
    assert p["signature"] == "小满的签名" and p["cover_path"]
    t = await pool.fetch("SELECT status, told FROM tarot_readings WHERE account_id = $1 ORDER BY created_at", acc)
    assert [(r["status"], r["told"]) for r in t] == [("done", True), ("failed", True)]   # 没解完的不在 Host 上偷偷花钱
    assert not (tmp_path / host_import.STAGING).exists()                                # 用完的暂存清掉


async def test_import_rooms_with_files_waits_for_missing(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    host_import.stage(tmp_path, _sha(PHOTO), PHOTO)                                     # 只传上来一张
    got = await host_import.run(pool, box, acc, bundle(rooms=rooms2()), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert got["rooms"].get("album") == 1 and "books" not in got["rooms"] and "food" not in got["rooms"]
    assert "book-marks" not in got["rooms"]                                             # 书没到，划线也等着
    need = await host_import.needed(pool, acc, tmp_path, rooms2())
    assert _sha(PHOTO) not in need and _sha(BOOK) in need                               # 搬过的不再要
    stage_all(tmp_path)
    got = await host_import.run(pool, box, acc, bundle(rooms=rooms2()), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert "album" not in got["rooms"] and got["rooms"]["books"] == 1 and got["rooms"]["book-marks"] == 2


async def test_import_files_endpoints(pool, tmp_path):
    from tests.test_host import client, make_app
    from brain import host
    app = make_app(pool, host_mode=True)
    app.state.api.cfg.files_dir = tmp_path
    acc = await host.owner(pool) or await auth.new_account(pool)
    token = await auth.new_session(pool, acc, secret="test-secret", now=NOW)
    async with client(app, token) as c:
        r = await c.post("/me/import/files", json={"rooms": rooms2()})
        assert r.status_code == 200 and _sha(PHOTO) in r.json()["missing"]
        r = await c.put(f"/me/import/files/{_sha(PHOTO)}", content=PHOTO)
        assert r.status_code == 204
        r = await c.put(f"/me/import/files/{_sha(PHOTO)}", content=b"xx")
        assert r.status_code == 400
        r = await c.post("/me/import/files", json={"rooms": rooms2()})
        assert _sha(PHOTO) not in r.json()["missing"]


async def test_import_milestones(pool, box, tmp_path):
    acc = await auth.new_account(pool)
    r = {"milestones": [{"id": 1, "companion_id": CID, "title": "第一次一起看海", "at": "2026-10-03T09:00:00Z"},
                        {"id": 2, "companion_id": "6b1f0c3e-9999-4a2b-9c3d-000000000009", "title": "别人的"}]}
    got = await host_import.run(pool, box, acc, bundle(rooms=r), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert got["rooms"] == {"milestones": 1}
    m = await pool.fetchrow("SELECT title, created_at FROM milestones WHERE account_id = $1", acc)
    assert m["title"] == "第一次一起看海" and m["created_at"] == datetime(2026, 10, 3, 9, tzinfo=timezone.utc)
    got = await host_import.run(pool, box, acc, bundle(rooms=r), files_dir=tmp_path, now=NOW, embedder=FakeEmbedder())
    assert got["rooms"] == {}
