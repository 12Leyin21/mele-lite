"""钱包记账（10-02）：记 / 改 / 删、一个月的账（分类、跟上个月比）、设置（币种、预算、自己加的分类）、
聊天里它替 TA 记、别人的看不到。测试用小满。"""
from datetime import datetime, timezone
from uuid import UUID

import pytest

from brain import wallet as W
from test_api import Env


def test_cents_and_money():
    assert W.cents("6.5") == 650 and W.cents("1,200") == 120000 and W.cents(23) == 2300
    for bad in ("", "abc", "-3", "0"):
        with pytest.raises(W.WalletError):
            W.cents(bad)
    assert W.money(650, "A$") == "A$6.50" and W.money(120000, "¥") == "¥1,200"


async def test_wallet_api_and_tool(pool):
    e = Env(pool, [{"calls": [("wallet", {"action": "add", "amount": "6.5", "category": "吃饭", "note": "咖啡"}),
                              ("wallet", {"action": "month"}), ("wallet", {"action": "tags"})]}, "记上啦"])
    e.deps.now = lambda: datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "tz": "Asia/Singapore"}})
        a = (await c.post("/wallet", json={"amount": "23", "category": "交通", "note": "打车"})).json()
        assert a["amount"] == 2300 and a["day"] == "2026-10-02"
        await c.post("/wallet", json={"amount": "100", "category": "购物", "day": "2026-09-15"})
        assert (await c.post("/wallet", json={"amount": "abc", "category": "吃饭"})).status_code == 400
        odd = (await c.post("/wallet", json={"amount": "1", "category": "奶茶"})).json()
        assert odd["category"] == "奶茶"                                       # 新标签：照记，还存进标签栏
        await c.post("/wallet", json={"amount": "200", "category": "打工", "kind": "in"})
        assert (await c.post("/wallet", json={"amount": "1", "category": "x", "kind": "gift"})).status_code == 400

        s = (await c.put("/wallet/settings", json={"currency": "cny", "budget": "500"})).json()
        assert s["currency"] == "CNY" and s["symbol"] == "¥" and s["budget"] == 50000 and s["categories"][-1] == "奶茶"
        assert "打工" in s["income_categories"]
        assert (await c.put("/wallet/settings", json={"currency": "XYZ"})).status_code == 400

        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "刚买咖啡花了 6.5"})
        await e.rooms.idle(UUID(conv["id"]))
        res = e.model.requests[1].rounds[0].results
        assert res[0].startswith("记好了") and "吃饭 ¥6.50" in res[0]
        assert res[2].startswith("支出的标签：吃饭、交通") and "奶茶" in res[2] and "打工" in res[2]
        assert "标签栏：" in res[1]
        assert "2026-10 一共花了 ¥30.50（上个月 ¥100）" in res[1] and "用了 6%" in res[1] and "收入 ¥200，结余 ¥169.50" in res[1]

        m = (await c.get("/wallet")).json()
        assert m["total"] == 3050 and m["income"] == 20000 and m["last_month"] == 10000 and m["by_category"][0] == ["交通", 2300]
        assert m["by_income"] == [["打工", 20000]]
        r = (await c.get("/wallet/receipt")).json()
        assert r["out"] == 3050 and r["income"] == 20000 and r["net"] == 16950 and r["no"] == 2 and len(r["entries"]) == 4

        # 偶尔提一句：TA 自己记的那几笔已经在刚才那一轮递过了；它替 TA 记的不算「没听说」
        acc = await pool.fetchval("SELECT account_id FROM companions")
        assert await W.pending_note(pool, acc, datetime(2026, 10, 2, 9, 30, tzinfo=timezone.utc), "zh") == ""
        await c.post("/wallet", json={"amount": "3", "category": "吃饭", "note": "包子"})
        assert await W.pending_note(pool, acc, datetime(2026, 10, 2, 10, 0, tzinfo=timezone.utc), "zh") == ""   # 隔不到半天
        note = await W.pending_note(pool, acc, datetime(2026, 10, 2, 22, 0, tzinfo=timezone.utc), "zh")
        assert note.startswith("〔钱包〕TA 最近记了：吃饭 ¥3（包子）")
        assert [x["author"] for x in m["entries"]].count(comp["id"]) == 1
        assert (await c.patch(f"/wallet/{a['id']}", json={"amount": "25"})).json()["amount"] == 2500
        assert (await c.delete(f"/wallet/{odd['id']}")).status_code == 204
        sep = (await c.get("/wallet", params={"month": "2026-09"})).json()
        assert sep["total"] == 10000
        assert len((await c.get("/me/export")).json()["wallet"]) == 5
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get("/wallet")).json()["entries"] == []
        assert (await c.delete(f"/wallet/{a['id']}")).status_code == 404
