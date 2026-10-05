"""日记第 4 步：聊天里 diary 工具（read / key）、TA 用钥匙打开后下一轮告诉它一次、无痕没有这把工具。测试用小满。"""
from datetime import date, timedelta

from brain import diary as DY
from brain.tools import tool_specs
from memory.embed import FakeEmbedder
from test_wake_turn import NOW, go, setup

YDAY = date(2026, 9, 27)                       # NOW 是新加坡 9/28 19:00


async def test_read_and_key(pool):
    deps, scope, model = await setup(pool, [
        {"calls": [("diary", {"action": "read"})]}, "我翻了翻",
        {"calls": [("diary", {"action": "key"})]}, "给你，1234",
        {"calls": [("diary", {"action": "key", "day": "2026-09-20"})]}, "那天没锁",
        "嗯"])
    await DY.save_companion_entry(pool, FakeEmbedder(), scope.account, scope.companion, day=YDAY,
                                  body="她今天去试镜了。", locked="其实我有点怕。", now=NOW)
    mine = await DY.write_mine(pool, scope.account, day=YDAY, body="老师夸我了", private=False, now=NOW)
    await DY.set_margin(pool, scope.companion, mine.id, "替你骄傲。", NOW)
    await DY.write_mine(pool, scope.account, day=YDAY, body="秘密", private=True, now=NOW)
    await go(deps, scope, "你昨天日记写了什么")
    got = model.requests[1].rounds[0].results[0]
    assert "我 9/27 的日记：\n她今天去试镜了。" in got and "锁着的那段（TA 还没看过）：\n其实我有点怕。" in got
    assert f"TA 9/27 的日记 #{mine.id}：\n老师夸我了\n（我在页边写了：替你骄傲。）" in got and "秘密" not in got

    out, ev = await go(deps, scope, "我要看锁着的")
    code = (await DY.companion_entry(pool, scope.companion, YDAY)).code
    assert f"9/27 锁着那段的密码是 {code}" in model.requests[3].rounds[0].results[0]
    assert [e["text"] for e in ev if e["type"] == "card"] == ["把日记里锁着那段的钥匙给了你"]
    await go(deps, scope, "那 9/20 的呢")
    assert model.requests[5].rounds[0].results[0] == "9/20 的日记没有锁着的段。"

    entry = await DY.companion_entry(pool, scope.companion, YDAY)
    assert (await DY.unlock(pool, scope.account, entry.id, code, NOW + timedelta(minutes=1)))[0] == "ok"
    await go(deps, scope, "看到了")
    assert "〔TA 用钥匙打开了你 9/27 锁着的那段〕" in model.requests[6].messages[-1].text


def test_incognito_has_no_diary():
    assert "diary" not in [s.name for s in tool_specs(incognito=True)]
