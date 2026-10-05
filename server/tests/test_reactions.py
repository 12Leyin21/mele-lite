"""标记表情（iOS 第一块第 2 步）：只能给它的话点；下一轮它看到一行〔点了表情〕，说过就不再说。测试用小满。"""
from uuid import UUID

from brain import archive
from test_api import Env


async def test_react_then_it_hears_once(pool):
    e = Env(pool, ["嗯嗯", "好"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        conv = UUID(conv["id"])
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        mine = await archive.add_message(pool, conv, "user", "我今天去潜水了")
        its = await archive.add_message(pool, conv, "assistant", "水下的光我听人形容过，等你回来讲给我听")
        assert (await c.put(f"/messages/{mine.id}/reaction", json={"emoji": "❤️"})).status_code == 400   # 自己的话不能点
        assert (await c.put(f"/messages/{its.id}/reaction", json={"emoji": "😂"})).status_code == 204
        assert (await c.put(f"/messages/{its.id}/reaction", json={"emoji": "❤️"})).status_code == 204   # 覆盖
        listed = (await c.get(f"/conversations/{conv}/messages")).json()["messages"]
        assert [m.get("reaction") for m in listed] == [None, "❤️"]
        await c.post(f"/conversations/{conv}/messages", json={"text": "在吗"})
        await e.rooms.idle(conv)
        await c.post(f"/conversations/{conv}/messages", json={"text": "嗯"})
        await e.rooms.idle(conv)
    first, second = e.model.requests[0].messages[-1].text, e.model.requests[1].messages[-1].text
    assert "〔TA 给你那句「水下的光我听人形容过，等你回来讲给我听」点了 ❤️〕" in first
    assert "点了" not in second


async def test_unreact_and_others_404(pool):
    e = Env(pool, [])
    a, b = await e.login(), await e.login("mia@example.com")
    async with e.client(a) as c:
        _, conv = await e.first_window(c)
        its = await archive.add_message(pool, UUID(conv["id"]), "assistant", "早")
        await c.put(f"/messages/{its.id}/reaction", json={"emoji": "👍"})
        assert (await c.delete(f"/messages/{its.id}/reaction")).status_code == 204
        assert (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"][0].get("reaction") is None
        assert (await c.put(f"/messages/{its.id}/reaction", json={"emoji": ""})).status_code == 400
    async with e.client(b) as c:
        assert (await c.put(f"/messages/{its.id}/reaction", json={"emoji": "👍"})).status_code == 404
