"""书架（10-02，照之前自用的 App共读书房）：切章、GBK、导入 / 列表 / 读章 / 打点、页边、划线说两句抄进页边、
〔在读〕、工具 book（翻页、留笔、不剧透、每天 3 笔）、别人的看不到。测试用小满。"""
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

from brain import books as BK
from test_api import Env
from test_stickers import pic

NOVEL = "\n".join(["序", "很久以前。",
                   "第一章 海边", "她在海边捡到一只瓶子。瓶子里有一封信。",
                   "第二章 来信", "信上写着：明天见。",
                   "第三章 结局", "他们最后没有见面。"])


def test_split_by_heads_and_fallback():
    chs = BK.split(NOVEL)
    assert [c[0] for c in chs] == ["序", "第一章 海边", "第二章 来信", "第三章 结局"]
    assert NOVEL[chs[1][1]:chs[1][2]].startswith("第一章 海边\n她在海边")
    plain = ("字" * 1000 + "\n") * 7
    parts = BK.split(plain)
    assert len(parts) >= 2 and parts[0][0] == "第 1 段" and parts[-1][2] == len(plain)
    assert BK.decode(NOVEL.encode("gb18030")) == NOVEL


async def test_shelf_reading_and_margin(pool, tmp_path):
    e = Env(pool, [{"calls": [("book", {"action": "page"}),
                              ("book", {"action": "mark", "quote": "瓶子里有一封信", "note": "像我们"}),
                              ("book", {"action": "mark", "quote": "他们最后没有见面"})]},
                   "这一页好安静",
                   "嗯，那封信大概是写给自己的"])
    clock = {"now": datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)}
    e.deps.now = lambda: clock["now"]
    e.app.state.api.cfg.files_dir = tmp_path
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        r = await c.post("/books", files={"file": ("海边.txt", NOVEL.encode("gb18030"), "text/plain")})
        assert r.status_code == 201
        b = r.json()
        assert b["title"] == "海边" and b["chapters"] == 4
        assert (await c.post("/books", files={"file": ("x.pdf", b"%PDF", "application/pdf")})).status_code == 400
        chs = (await c.get(f"/books/{b['id']}/chapters")).json()
        assert [x["title"] for x in chs][1] == "第一章 海边"
        assert "瓶子" in (await c.get(f"/books/{b['id']}/chapters/1")).json()["text"]

        await c.post(f"/books/{b['id']}/reading", json={"chapter": 1, "page": 0, "page_count": 1, "seconds": 60})
        await c.post(f"/books/{b['id']}/reading", json={"chapter": 1, "page": 0, "page_count": 1, "seconds": 60})
        shelf = (await c.get("/books")).json()
        assert shelf[0]["today_minutes"] == 2 and shelf[0]["at_chapter"] == 1

        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我在看书"})
        await e.rooms.idle(UUID(conv["id"]))
        last = e.model.requests[0].messages[-1].text
        assert "〔在读〕TA 正在读《海边》第一章 海边" in last
        res = e.model.requests[1].rounds[0].results
        assert "瓶子里有一封信" in res[0] and res[1].startswith("划好了")
        assert "没找到这一句" in res[2]                                           # 第三章 TA 还没读到：不剧透
        ms = (await c.get(f"/books/{b['id']}/marks", params={"chapter": 1})).json()
        assert [(m["author"], m["quote"], m["note"]) for m in ms] == [(comp["id"], "瓶子里有一封信", "像我们")]

        # 划线说两句：先建线头，再带着 book_mark_id 发进聊天；它的回话抄一份进页边
        root = (await c.post(f"/books/{b['id']}/marks", json={"chapter": 2, "quote": "明天见", "note": "这句好难过",
                                                               "companion_id": comp["id"]})).json()
        await c.post(f"/conversations/{conv['id']}/messages",
                     json={"text": "「回复：明天见」\n这句好难过", "book_mark_id": root["id"]})
        await e.rooms.idle(UUID(conv["id"]))
        thread = [m for m in (await c.get(f"/books/{b['id']}/marks")).json() if m["parent_id"] == root["id"]]
        assert [(m["author"], m["note"], m["chapter"]) for m in thread] == [(comp["id"], "嗯，那封信大概是写给自己的", 2)]
        reply = (await c.post(f"/books/{b['id']}/marks", json={"parent_id": root["id"], "note": "嗯"})).json()
        assert reply["chapter"] == 2 and reply["parent_id"] == root["id"]

        assert (await c.delete(f"/books/{b['id']}/marks/{ms[0]['id']}")).status_code == 404   # 它写的删不了
        assert (await c.delete(f"/books/{b['id']}/marks/{root['id']}")).status_code == 204
        assert not [m for m in (await c.get(f"/books/{b['id']}/marks")).json() if m["chapter"] == 2]

        assert (await c.put(f"/books/{b['id']}/cover", files={"file": ("c.png", pic(), "image/png")})).status_code == 204
        assert (await c.get(f"/books/{b['id']}/cover")).status_code == 200
        export = (await c.get("/me/export")).json()
        assert export["books"][0]["title"] == "海边"

        clock["now"] += timedelta(minutes=10)                                    # 过了 3 分钟：不再给〔在读〕
        acc = await pool.fetchval("SELECT account_id FROM companions")
        assert await BK.reading_line(pool, acc, clock["now"], "zh") == ""

    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/books")).json() == []
        assert (await c.get(f"/books/{b['id']}/chapters/1")).status_code == 404
        assert (await c.get(f"/books/{b['id']}/marks")).status_code == 404
    async with e.client(t) as c:
        path = await pool.fetchval("SELECT path FROM books WHERE id = $1", b["id"])
        assert (await c.delete(f"/books/{b['id']}")).status_code == 204 and not Path(path).exists()


async def test_marks_per_day(pool, tmp_path):
    acc_comp = await pool.fetchval("SELECT 1")
    assert acc_comp == 1
    from brain import accounts
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    now = datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)
    b = await BK.add(pool, tmp_path, acc, name="a.txt", data=NOVEL.encode(), now=now)
    for _ in range(3):
        await BK.add_mark(pool, acc, b.id, chapter=1, quote="她在海边", note="", author=str(comp), companion=comp, now=now)
    assert await BK.marks_today(pool, acc, comp, now - timedelta(hours=1)) == 3
