"""日记第 5 步：/diary 接口。测试用小满。"""
import random
from datetime import date, datetime, timedelta, timezone

from brain import diary as DY
from memory.embed import FakeEmbedder
from test_api import Env

NOW = datetime(2026, 10, 1, 6, 0, tzinfo=timezone.utc)            # 新加坡 10/1 14:00


async def test_write_list_edit_delete(pool):
    e = Env(pool)
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore"}})
        r = await c.post("/diary", json={"body": "今天试镜"})
        assert r.status_code == 200 and r.json()["day"] == "2026-10-01" and not r.json()["private"]
        mine = r.json()["id"]
        assert (await c.post("/diary", json={"body": "  "})).status_code == 400
        assert (await c.post("/diary", json={"body": "x", "day": "昨天"})).status_code == 400
        old = (await c.post("/diary", json={"body": "前几天的", "day": "2026-09-28", "private": True})).json()
        await DY.save_companion_entry(pool, FakeEmbedder(), (await pool.fetchval("SELECT account_id FROM companions")),
                                      comp["id"], day=date(2026, 9, 30), body="Ta 的", locked="锁着", now=NOW)
        rows = (await c.get("/diary")).json()
        assert [(x["day"], x["author"]) for x in rows] == [("2026-10-01", "user"), ("2026-09-30", "companion"),
                                                            ("2026-09-28", "user")]
        assert rows[1]["has_locked"] and "locked" not in rows[1] and "code" not in rows[1]
        assert [x["day"] for x in (await c.get("/diary", params={"before": "2026-10-01"})).json()] == ["2026-09-30", "2026-09-28"]
        r = await c.patch(f"/diary/{old['id']}", json={"private": False, "body": "改过"})
        assert r.json()["body"] == "改过" and not r.json()["private"]
        assert (await c.patch(f"/diary/{rows[1]['id']}", json={"body": "改 Ta 的"})).status_code == 404
        assert (await c.delete(f"/diary/{rows[1]['id']}")).status_code == 404               # Ta 的删不了
        assert (await c.delete(f"/diary/{mine}")).status_code == 204
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/diary")).json() == []
        assert (await c.patch(f"/diary/{old['id']}", json={"body": "偷改"})).status_code == 404


async def test_unlock(pool):
    e = Env(pool)
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        acc = await pool.fetchval("SELECT account_id FROM companions")
        entry = await DY.save_companion_entry(pool, FakeEmbedder(), acc, comp["id"], day=date(2026, 9, 30),
                                              body="正文", locked="锁着那段", now=NOW)
        plain = await DY.save_companion_entry(pool, FakeEmbedder(), acc, comp["id"], day=date(2026, 9, 29),
                                              body="没锁", locked="", now=NOW)
        assert (await c.post(f"/diary/{entry.id}/unlock", json={"code": "1234"})).status_code == 409
        assert (await c.post(f"/diary/{plain.id}/unlock", json={"code": "1234"})).status_code == 409
        code = await DY.give_key(pool, comp["id"], date(2026, 9, 30), random.Random(3), NOW)
        wrong = "0000" if code != "0000" else "1111"
        r = await c.post(f"/diary/{entry.id}/unlock", json={"code": wrong})
        assert r.status_code == 403 and r.json()["left"] == 4
        for _ in range(4):
            r = await c.post(f"/diary/{entry.id}/unlock", json={"code": wrong})
        assert r.status_code == 423 and r.json()["wait_seconds"] == 600
        e.deps.now = lambda: NOW + timedelta(minutes=11)
        r = await c.post(f"/diary/{entry.id}/unlock", json={"code": code})
        assert r.status_code == 200 and r.json()["locked"] == "锁着那段"
        assert (await c.post("/diary/99999/unlock", json={"code": code})).status_code == 404
