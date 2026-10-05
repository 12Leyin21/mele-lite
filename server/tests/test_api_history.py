"""聊天记录的翻页、搜索、按天（iOS 第一块第 1 步）。借 test_api 的 Env；测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from brain import archive
from test_api import Env

T0 = datetime(2026, 9, 27, 14, 0, tzinfo=timezone.utc)      # 新加坡 22:00


async def window(e, c):
    comp, conv = await e.first_window(c)
    await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore"}})
    return UUID(conv["id"])


async def test_before_pages_back(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        conv = await window(e, c)
        ids = [(await archive.add_message(pool, conv, "user" if i % 2 == 0 else "assistant", f"第{i}句",
                                          now=T0 + timedelta(minutes=i))).id for i in range(7)]
        r = (await c.get(f"/conversations/{conv}/messages", params={"before": ids[5], "limit": 3})).json()
        assert [m["text"] for m in r["messages"]] == ["第2句", "第3句", "第4句"] and r["has_more"] is True
        r = (await c.get(f"/conversations/{conv}/messages", params={"before": ids[2], "limit": 3})).json()
        assert [m["text"] for m in r["messages"]] == ["第0句", "第1句"] and r["has_more"] is False


async def test_search_skips_thinking_and_wake(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        conv = await window(e, c)
        await archive.add_message(pool, conv, "user", "今晚看星际穿越", now=T0)
        await archive.add_message(pool, conv, "assistant", "好呀", thinking="她要看星际穿越，录像带那段", now=T0 + timedelta(minutes=1))
        await archive.add_message(pool, conv, "wake", "〔醒来〕星际穿越", now=T0 + timedelta(minutes=2))
        await archive.add_message(pool, conv, "assistant", "星际穿越看完了吗", now=T0 + timedelta(minutes=3))
        hits = (await c.get(f"/conversations/{conv}/search", params={"q": "星际"})).json()["hits"]
        assert [h["message"]["text"] for h in hits] == ["星际穿越看完了吗", "今晚看星际穿越"]       # 新的在前
        assert hits[1]["after"]["text"] == "好呀" and hits[1]["before"] is None
        assert (await c.get(f"/conversations/{conv}/search", params={"q": "录像带"})).json()["hits"] == []
        assert (await c.get(f"/conversations/{conv}/search", params={"q": " "})).status_code == 400


async def test_day_uses_companion_time_zone(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        conv = await window(e, c)
        await archive.add_message(pool, conv, "user", "新加坡 27 号晚上", now=T0)                        # 27 日 22:00
        await archive.add_message(pool, conv, "user", "新加坡 28 号凌晨", now=T0 + timedelta(hours=3))   # 28 日 01:00
        r = (await c.get(f"/conversations/{conv}/messages", params={"day": "2026-09-28"})).json()
        assert [m["text"] for m in r["messages"]] == ["新加坡 28 号凌晨"]
        assert (await c.get(f"/conversations/{conv}/messages", params={"day": "昨天"})).status_code == 400


async def test_other_people_cannot_search(pool):
    e = Env(pool)
    a, b = await e.login(), await e.login("mia@example.com")
    async with e.client(a) as c:
        conv = await window(e, c)
    async with e.client(b) as c:
        assert (await c.get(f"/conversations/{conv}/search", params={"q": "x"})).status_code == 404


async def test_messages_come_with_bubbles(pool):
    """app 按服务器切好的气泡显示：它的话跟事件流里推的一样切，TA 连发的几句还是几个气泡（iOS 第 7 步）。"""
    e = Env(pool, ["嗯嗯。\n\n三件事我都听到了。"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 1}})
        for i, text in enumerate(["今天好累", "开了一天会\n真的很长"]):
            await c.post(f"/conversations/{conv['id']}/messages", json={"text": text, "client_id": f"b{i}"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        assert msgs[0]["text"] == "今天好累\n开了一天会\n真的很长"                 # 它看到的还是拼好的一句
        assert msgs[0]["bubbles"] == ["今天好累", "开了一天会\n真的很长"]
        assert msgs[1]["bubbles"] == ["嗯嗯。", "三件事我都听到了。"]
        one = await archive.add_message(pool, UUID(conv["id"]), "user", "单独一句\n两行")
        got = (await c.get(f"/conversations/{conv['id']}/messages", params={"after": one.id - 1})).json()["messages"]
        assert got[0]["bubbles"] == ["单独一句\n两行"]


async def test_messages_keep_public_action_cards(pool):
    """动作卡片跟着它那句存下来，app 刷新后还在；便利贴这种不挂的不存（iOS 第 7 步）。"""
    e = Env(pool, [{"calls": [("memory_remember", {"content": "小满对芒果过敏", "importance": 8}),
                              ("sticky_note", {"text": "周五问问小满体检结果"})]},
                   "记下啦"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我对芒果过敏"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
    assert msgs[0]["cards"] == []
    assert [k["kind"] for k in msgs[1]["cards"]] == ["remember"] and "芒果" in msgs[1]["cards"][0]["text"]


async def test_calendar_days_in_companion_time_zone(pool):
    """聊天日历：哪几天聊过（联系人时区）、那天几句、第一句的号；〔醒来〕不算（iOS 第 9 步）。"""
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        conv = await window(e, c)
        a = await archive.add_message(pool, conv, "user", "27 号晚上", now=T0)                      # 新加坡 27 日 22:00
        await archive.add_message(pool, conv, "assistant", "嗯", now=T0 + timedelta(minutes=1))
        await archive.add_message(pool, conv, "wake", "〔醒来〕", now=T0 + timedelta(hours=2, minutes=30))
        b = await archive.add_message(pool, conv, "assistant", "28 号凌晨", now=T0 + timedelta(hours=3))   # 28 日 01:00
        days = (await c.get(f"/conversations/{conv}/calendar")).json()["days"]
    assert days == [{"day": "2026-09-27", "count": 2, "first_id": a.id},
                    {"day": "2026-09-28", "count": 1, "first_id": b.id}]
