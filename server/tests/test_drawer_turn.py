"""抽屉第 5 步：drawer 工具、倒回、解锁日推送、〔醒来〕里那行、「TA 拆了」只说一次、推送的样子。测试用小满。"""
import json
from datetime import date, datetime, timedelta, timezone

from brain import archive, rewind
from brain import drawer as D
from brain.tools import tool_specs
from brain.wake_text import render_wake
from patrol.wake import wake_turn
from push.apns import send_pending
from test_patrol_wake import World
from test_push import cfg
from test_wake_turn import NOW, TZ, go, setup


async def noop(_):
    return None


def put(**kw):
    return {"calls": [("drawer", {"action": "put", **kw})]}


async def test_put_key_mine_burn(pool):
    deps, scope, model = await setup(pool, [
        put(title="给你的", content="生日快乐", unlock_at="2026-12-21"), "嗯",
        {"calls": [("drawer", {"action": "key", "id": 0})]}, "密码是……",
        {"calls": [("drawer", {"action": "mine"})]}, {"calls": [("drawer", {"action": "burn", "id": 0})]}, "好"])
    out, ev = await go(deps, scope, "嗯")
    assert [(e["kind"], e["text"], e["private"]) for e in ev if e["type"] == "card"] == \
        [("drawer", "往抽屉里放了一封 · 12/21 解锁", False)]
    [letter] = await D.mine(pool, scope.companion)
    assert (letter.title, letter.content, letter.unlock_at) == ("给你的", "生日快乐", date(2026, 12, 21))

    model.script[0] = {"calls": [("drawer", {"action": "key", "id": letter.id})]}
    out, ev = await go(deps, scope, "我能提前看吗")
    code = await pool.fetchval("SELECT code FROM drawer_letters WHERE id = $1", letter.id)
    assert len(code) == 4 and f"#{letter.id} 的密码是 {code}" in model.requests[3].rounds[0].results[0]
    assert [e["text"] for e in ev if e["type"] == "card"] == ["把一封信的钥匙给了你"]

    model.script[1] = {"calls": [("drawer", {"action": "burn", "id": letter.id})]}
    out, ev = await go(deps, scope, "算了")
    listing = model.requests[5].rounds[0].results[0]
    assert f"#{letter.id}" in listing and "12/21 解锁" in listing and f"钥匙给过（{code}）" in listing and "生日快乐" in listing
    assert [e["text"] for e in ev if e["type"] == "card"] == ["烧掉了一封"]
    assert await D.mine(pool, scope.companion) == []


async def test_put_rewinds_and_not_in_incognito(pool):
    deps, scope, _ = await setup(pool, [put(content="偷偷写的"), "好"])
    await go(deps, scope, "嗯")
    user = (await archive.recent(pool, scope.conversation))[0]
    await rewind.rewind_to_user(pool, deps.embedder, scope, user.id)
    assert await pool.fetchval("SELECT count(*) FROM drawer_letters") == 0
    assert "drawer" in [t.name for t in tool_specs()] and "drawer" not in [t.name for t in tool_specs(incognito=True)]


async def test_opened_line_only_once(pool):
    deps, scope, model = await setup(pool, ["你拆啦", "嗯嗯"])
    letter = await D.put(pool, scope.account, scope.companion, title="秋天", content="风很好", unlock_at=None, now=NOW)
    await pool.execute("UPDATE drawer_letters SET opened_at = $2 WHERE id = $1", letter.id, NOW)
    await go(deps, scope, "我拆了")
    await go(deps, scope, "嗯")
    assert "〔TA 拆了你 9/28 写的那封《秋天》〕" in model.requests[0].messages[-1].text
    assert "TA 拆了" not in model.requests[1].messages[-1].text


async def test_wake_mentions_due_letters(pool):
    w = await World().build(pool, ["嗨"])
    await D.put(pool, w.acc, w.comp, title="", content="a", unlock_at=date(2026, 9, 28), now=w.now - timedelta(days=3))
    await D.put(pool, w.acc, w.comp, title="", content="b", unlock_at=None, now=w.now)
    from brain.scope import Scope
    await wake_turn(w.deps, Scope(w.acc, w.comp, w.conv), "whim", "", w.now, noop)
    assert "抽屉里有 2 封，1 封到了日子 TA 还没拆。" in w.model.requests[0].messages[-1].text


async def test_no_drawer_line_when_nothing_is_due(pool):
    w = await World().build(pool, ["嗨"])
    await D.put(pool, w.acc, w.comp, title="", content="b", unlock_at=None, now=w.now)
    from brain.scope import Scope
    await wake_turn(w.deps, Scope(w.acc, w.comp, w.conv), "whim", "", w.now, noop)
    assert "抽屉" not in w.model.requests[0].messages[-1].text


async def test_unlock_push_once_merged_after_waking(pool):
    w = await World().build(pool, [])
    for c in ("a", "b"):
        await D.put(pool, w.acc, w.comp, title="", content=c, unlock_at=date(2026, 10, 1), now=w.now)
    early = datetime(2026, 9, 30, 23, 0, tzinfo=timezone.utc)          # 新加坡 10/1 07:00，还没到起床（08:00）
    assert await D.queue_unlocks(pool, early) == 0
    up = datetime(2026, 10, 1, 0, 5, tzinfo=timezone.utc)              # 08:05
    assert await D.queue_unlocks(pool, up) == 1
    assert await D.queue_unlocks(pool, up + timedelta(hours=1)) == 0   # 只推一次
    row = await pool.fetchrow("SELECT kind, text, conversation_id FROM push_queue")
    assert (row["kind"], row["text"], row["conversation_id"]) == ("drawer", "有 2 封今天解锁了", w.conv)

    await pool.execute("UPDATE push_queue SET created_at = now()")
    await pool.execute("INSERT INTO devices (account_id, apns_token, updated_at) VALUES ($1, 'tok', now())", w.acc)
    sent = []

    async def transport(url, headers, body):
        sent.append(json.loads(body))
        return 200, ""
    assert await send_pending(pool, cfg(), transport) == 1
    assert sent == [{"aps": {"alert": {"title": "抽屉", "body": "有 2 封今天解锁了"}, "sound": "default"},
                     "room": "drawer"}]
