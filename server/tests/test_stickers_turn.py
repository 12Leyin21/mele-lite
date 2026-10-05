"""表情包第 4 步：它用 sticker 工具找、发（挂一张 kind=sticker 的卡，跟回复一起存）；只给别人的发不了。测试用小满。"""
from brain import archive
from brain import stickers as S
from brain.tools import tool_specs
from test_stickers import pic
from test_wake_turn import go, setup


async def test_search_and_send(pool, tmp_path):
    deps, scope, model = await setup(pool, [
        {"calls": [("sticker", {"action": "search", "query": "得意"})]},
        {"calls": [("sticker", {"action": "send", "id": 0})]}, "哼哼", "嗯"])
    smug, _ = await S.add(pool, deps.embedder, tmp_path, scope.account, data=pic((1, 1, 1)),
                          caption="一只叉腰的猫，很得意", name="叉腰")
    model.script[1] = {"calls": [("sticker", {"action": "send", "id": smug.id})]}
    out, ev = await go(deps, scope, "我今天被夸了！")
    found = model.requests[1].rounds[0].results[0]
    assert found == f"#{smug.id} 一只叉腰的猫，很得意（TA 叫它「叉腰」）"
    cards = [e for e in ev if e["type"] == "card"]
    assert [(c["kind"], c["data"], c["private"]) for c in cards] == [("sticker", {"sticker_id": smug.id}, False)]
    msg = (await archive.recent(pool, scope.conversation))[-1]
    assert msg.text == "哼哼" and "发了表情包「#" in msg.tools
    assert await pool.fetchval("SELECT use_count FROM stickers WHERE id = $1", smug.id) == 1


async def test_only_for_someone_else_cannot_be_sent(pool, tmp_path):
    from brain import accounts
    deps, scope, model = await setup(pool, [{"calls": [("sticker", {"action": "send", "id": 0})]}, "嗯"])
    other = await accounts.create_companion(pool, scope.account)
    s, _ = await S.add(pool, deps.embedder, tmp_path, scope.account, data=pic((2, 2, 2)), caption="小狗哭")
    await S.update(pool, deps.embedder, scope.account, s.id, only_for=[other])
    model.script[0] = {"calls": [("sticker", {"action": "send", "id": s.id})]}
    await go(deps, scope, "嗯")
    assert model.requests[1].rounds[0].results[0].startswith("没有这张")


def test_incognito_has_no_sticker_tool():
    assert "sticker" not in [s.name for s in tool_specs(incognito=True)]
