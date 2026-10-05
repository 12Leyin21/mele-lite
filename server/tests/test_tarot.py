"""塔罗（10-03）：洗牌可复现、正逆位比例、存档按牌序取牌（交不了假牌）、追问、导出、它翻得到的局。测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest

from brain import tarot as T
from test_api import Env

NOW = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)


def test_shuffle_is_reproducible_and_fair():
    a, b = T.shuffle("seed-1"), T.shuffle("seed-1")
    assert a == b and len(a) == 78 and len({c["card"] for c in a}) == 78
    assert T.shuffle("seed-2") != a
    flips = sum(c["reversed"] for i in range(130) for c in T.shuffle(f"s{i}"))
    assert 0.32 <= flips / (130 * 78) <= 0.38                                   # 正位 0.65
    assert T.make_seed("轨迹") != T.make_seed("轨迹")                            # 服务器那一半是真随机


async def _setup(pool):
    e = Env(pool, [""])
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
    cid = UUID(comp["id"])
    acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", cid)
    return e, acc, cid


async def test_save_takes_cards_from_the_stored_deck(pool):
    _, acc, comp = await _setup(pool)
    did, deck = await T.new_deck(pool, acc, "trail", NOW)
    r = await T.save(pool, acc, deck_id=did, spread="three", question="  这周会顺吗 ", reader=comp, route_from=comp,
                     picks=[5, 0, 77], mode="hand", now=NOW)
    assert r.question == "这周会顺吗" and r.status == "pending" and r.companion_id == comp
    assert [c["position"] for c in r.cards] == ["过去", "现在", "未来"]
    assert [(c["card"], c["reversed"]) for c in r.cards] == [(deck[i]["card"], deck[i]["reversed"]) for i in (5, 0, 77)]
    with pytest.raises(T.TarotError):                                           # 用过的牌就没了
        await T.save(pool, acc, deck_id=did, spread="single", question="q", reader=None, route_from=comp,
                     picks=[1], mode="hand", now=NOW)
    pub = r.public("zh")
    assert pub["spread_name"] == "三张" and pub["cards"][0]["name"] and len(pub["cards"][0]["keywords"]) >= 3


@pytest.mark.parametrize("picks", [[1, 2], [1, 1, 2], [0, 1, 78], [-1, 0, 1], ["a", 1, 2]])
async def test_bad_picks_rejected(pool, picks):
    _, acc, comp = await _setup(pool)
    did, _ = await T.new_deck(pool, acc, "", NOW)
    with pytest.raises(T.TarotError):
        await T.save(pool, acc, deck_id=did, spread="three", question="q", reader=comp, route_from=comp,
                     picks=picks, mode="hand", now=NOW)


async def test_deck_expires_and_is_private(pool):
    e, acc, comp = await _setup(pool)
    did, _ = await T.new_deck(pool, acc, "", NOW - timedelta(minutes=31))
    with pytest.raises(T.TarotError):
        await T.save(pool, acc, deck_id=did, spread="single", question="q", reader=comp, route_from=comp,
                     picks=[0], mode="auto", now=NOW)
    other = await pool.fetchval("INSERT INTO accounts (id) VALUES (gen_random_uuid()) RETURNING id")
    did2, _ = await T.new_deck(pool, other, "", NOW)
    with pytest.raises(T.TarotError):                                           # 别人的牌
        await T.save(pool, acc, deck_id=did2, spread="single", question="q", reader=comp, route_from=comp,
                     picks=[0], mode="auto", now=NOW)
    with pytest.raises(T.TarotError):
        await T.save(pool, acc, deck_id=did2, spread="followup", question="q", reader=comp, route_from=comp,
                     picks=[0], mode="auto", now=NOW)


async def test_followup_needs_interpretation_and_tool_view(pool):
    _, acc, comp = await _setup(pool)
    did, _ = await T.new_deck(pool, acc, "", NOW)
    r = await T.save(pool, acc, deck_id=did, spread="single", question="要不要去", reader=comp, route_from=comp,
                     picks=[3], mode="auto", now=NOW)
    did, deck = await T.new_deck(pool, acc, "", NOW)
    with pytest.raises(T.TarotError):
        await T.add_followup(pool, acc, r.id, deck_id=did, pick=0, question="那什么时候", mode="hand", now=NOW)
    await T.write(pool, r.id, "去吧。")
    got = await T.get(pool, acc, r.id)
    assert got.status == "done" and got.told is False                          # TA 抽、它解 → 下一轮递〔塔罗〕
    r2, i = await T.add_followup(pool, acc, r.id, deck_id=did, pick=9, question="那什么时候", mode="hand", now=NOW)
    assert i == 0 and r2.followups[0]["card"]["card"] == deck[9]["card"] and r2.followups[0]["card"]["position"] == "追问"
    await T.write(pool, r.id, "下周。", followup=0)
    assert (await T.get(pool, acc, r.id)).followups[0]["interpretation"] == "下周。"

    did, _ = await T.new_deck(pool, acc, "", NOW)
    neutral = await T.save(pool, acc, deck_id=did, spread="single", question="中立的", reader=None, route_from=comp,
                           picks=[0], mode="auto", now=NOW)
    await T.write(pool, neutral.id, "平实的话。")
    assert (await T.get(pool, acc, neutral.id)).told is True                   # 解牌人的局不告诉任何联系人
    mine = await T.save_tool(pool, acc, comp, question="我该不该主动", spread="three", for_ta=False, now=NOW)
    assert mine.asker == "contact" and mine.mode == "tool" and len(mine.cards) == 3
    seen = {x.id for x in await T.for_tool(pool, comp)}
    assert seen == {r.id, mine.id}
    assert len(await T.export(pool, acc)) == 3
    assert [x.id for x in await T.list_all(pool, acc, asker="contact")] == [mine.id]


async def test_tarot_api(pool):
    import asyncio
    e = Env(pool, [{"calls": [("tarot_write", {"text": "三张都在说：慢慢来。"})]}, ""])
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        sp = (await c.get("/tarot/spreads")).json()
        assert len(sp) == 9 and sp[1]["key"] == "three" and sp[1]["count"] == 3
        cards = (await c.get("/tarot/cards")).json()
        assert len(cards) == 78 and cards[0]["name"] == "愚人" and len(cards[0]["upright"]) >= 3
        d = (await c.post("/tarot/deck", json={"trail": "12,40;13,42"})).json()
        assert len(d["deck"]) == 78
        bad = await c.post("/tarot/readings", json={"deck_id": d["deck_id"], "spread": "three", "question": "q",
                                                    "reader": comp["id"], "picks": [1, 2], "mode": "hand"})
        assert bad.status_code == 400
        r = await c.post("/tarot/readings", json={"deck_id": d["deck_id"], "spread": "three", "question": "下周顺吗",
                                                  "reader": comp["id"], "from": comp["id"], "picks": [7, 8, 9],
                                                  "mode": "hand"})
        assert r.status_code == 201
        got = r.json()
        assert got["cards"][0]["card"] == d["deck"][7]["card"] and got["reader"] == comp["id"]
        for _ in range(50):                                                      # 后台在解
            one = (await c.get(f"/tarot/readings/{got['id']}")).json()
            if one["status"] == "done":
                break
            await asyncio.sleep(0.02)
        assert one["interpretation"] == "三张都在说：慢慢来。"
        assert [x["id"] for x in (await c.get("/tarot/readings", params={"companion_id": comp["id"]})).json()] == [got["id"]]
        assert (await c.post(f"/tarot/readings/{got['id']}/retry")).status_code == 409
        assert len((await c.get("/me/export")).json()["tarot"]) == 1
        assert (await c.delete(f"/tarot/readings/{got['id']}")).status_code == 204
        assert (await c.get(f"/tarot/readings/{got['id']}")).status_code == 404
    other = await e.login("mia@example.com")
    async with e.client(other) as c2:
        assert (await c2.get(f"/tarot/readings/{got['id']}")).status_code == 404


async def test_tarot_note_and_tool_in_chat(pool):
    from brain import tarot_read as TR
    e = Env(pool, [{"calls": [("tarot_write", {"text": "这张说先别急着回复。"})]}, ""])
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        cid = UUID(comp["id"])
        acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", cid)
        did, _ = await T.new_deck(pool, acc, "", NOW)
        r = await T.save(pool, acc, deck_id=did, spread="single", question="要不要回他消息", reader=cid, route_from=cid,
                         picks=[0], mode="hand", now=NOW)
        await TR.read_now(e.deps, acc, r.id)
        did, _ = await T.new_deck(pool, acc, "", NOW)
        n = await T.save(pool, acc, deck_id=did, spread="single", question="中立那局", reader=None, route_from=cid,
                         picks=[0], mode="hand", now=NOW)
        await T.write(pool, n.id, "解牌人的话")

        e.model.script = [{"calls": [("tarot", {"action": "draw", "question": "帮小满抽：周末去不去海边", "for_ta": True})]},
                          "抽到了，我跟你说～", "嗯"]
        k = len(e.model.requests)

        def seen(req) -> str:
            return "\n".join([b.text for b in req.system] + [m.text for m in req.messages])
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "帮我抽一张"})
        await e.rooms.idle(UUID(conv["id"]))
        first = e.model.requests[k]
        assert "〔塔罗〕" in seen(first) and "要不要回他消息" in seen(first) and "先别急着回复" in seen(first)
        assert "中立那局" not in seen(first) and "解牌人的话" not in seen(first)
        assert "tarot" in [x.name for x in first.tools]
        drawn = [x for x in await T.list_all(pool, acc) if x.mode == "tool"][0]
        assert drawn.asker == "user" and drawn.drawn_by == "contact" and drawn.companion_id == cid

        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "好"})
        await e.rooms.idle(UUID(conv["id"]))
        assert seen(e.model.requests[-1]).count("〔塔罗〕TA 在塔罗房间") <= 1                    # 只递一次（历史里那次不算新的）
        assert await pool.fetchval("SELECT count(*) FROM tarot_readings WHERE NOT told") == 0

    from brain.tools import ToolContext, run_tool
    from llm.types import ToolCall
    ctx = ToolContext(pool=pool, embedder=e.deps.embedder, user_id=cid, account_id=acc, now=NOW)
    out = await run_tool(ctx, ToolCall("1", "tarot", {"action": "read", "id": r.id, "text": "改写 TA 的局"}))
    assert "只能给你自己抽的" in out
    assert "写好了。" == await run_tool(ctx, ToolCall("2", "tarot", {"action": "read", "id": drawn.id, "text": "去吧，带件外套。"}))
    assert (await T.get(pool, acc, drawn.id)).interpretation == "去吧，带件外套。"
    listed = await run_tool(ctx, ToolCall("3", "tarot", {"action": "list"}))
    assert "周末去不去海边" in listed and "中立那局" not in listed
