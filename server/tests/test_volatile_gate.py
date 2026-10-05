"""易变区瘦身（09-30 Tilia：每轮喂的别太多，会变的不用每轮都给）。
便利贴、快到的远事：变了才给、隔两小时再给、醒来时给；跟〔TA 那边〕一个规矩。测试用小满。"""
from datetime import date, timedelta

import memory as M
from brain import far_dates as FD
from brain.settings import Settings
from test_wake_turn import NOW, TZ, go, setup


def volatile(model, i=-1) -> str:
    return "\n".join(m.text for m in model.requests[i].messages)


async def test_sticky_and_near_dates_are_not_repeated_every_turn(pool):
    deps, scope, model = await setup(pool, ["嗯", "好", "对", "在呢", "嗨"])
    clock = {"now": NOW}
    deps.now = lambda: clock["now"]
    await M.set_sticky(pool, scope.companion, "周五问 TA 面试结果")
    await FD.add(pool, scope.account, scope.companion, Settings.from_dict({"tz": TZ}), day=date(2026, 9, 29),
                 title="牙医", now=NOW)
    await go(deps, scope, "在吗")
    assert "面试结果" in volatile(model) and "牙医" in volatile(model)                 # 第一轮给
    clock["now"] += timedelta(minutes=5)
    await go(deps, scope, "今天好累")
    assert "面试结果" not in volatile(model) and "牙医" not in volatile(model)         # 没变：不再给
    await M.set_sticky(pool, scope.companion, "周五问 TA 面试结果\n周日提醒买菜")
    clock["now"] += timedelta(minutes=5)
    await go(deps, scope, "嗯嗯")
    assert "买菜" in volatile(model) and "牙医" not in volatile(model)                # 便利贴变了：给便利贴
    clock["now"] += timedelta(hours=2)
    await go(deps, scope, "我回来啦")
    assert "买菜" in volatile(model) and "牙医" in volatile(model)                    # 隔了两小时：都再给一次
    clock["now"] += timedelta(minutes=1)
    await go(deps, scope, "", wake="〔醒来〕测试")
    assert "买菜" in volatile(model) and "牙医" in volatile(model)                    # 醒来：给
