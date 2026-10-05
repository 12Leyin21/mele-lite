"""待办第 1 步：常去的地方、待办三个格子、打勾一期一期、挂钟、收编老的「你定的钟」。测试用小满。"""
from datetime import date, datetime, timedelta, timezone

import pytest

from brain import accounts, archive
from brain import todos as T
from patrol import store as clock_store

TZ_SG = "Asia/Singapore"
NOW = datetime(2026, 10, 1, 4, 0, tzinfo=timezone.utc)             # 新加坡 10/1 周四 12:00
TODAY = date(2026, 10, 1)


async def people(pool):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, comp, {"tz": TZ_SG})
    return acc, comp


async def test_places(pool):
    acc, comp = await people(pool)
    school = await T.add_place(pool, acc, name="学校", lat=-31.98, lon=115.82, radius=50)
    assert school.radius == 100                                                       # 太小的拉到 100 米
    with pytest.raises(ValueError):
        await T.add_place(pool, acc, name="", lat=0, lon=0)
    with pytest.raises(ValueError):
        await T.add_place(pool, acc, name="月球", lat=95, lon=0)
    await pool.execute("UPDATE places SET inside = TRUE WHERE id = $1", school.id)
    assert (await T.update_place(pool, acc, school.id, name="UWA")).inside is True    # 只改名字不清状态
    assert (await T.update_place(pool, acc, school.id, lat=-31.9)).inside is None     # 挪了位置 = 不知道在不在
    assert (await T.place_by_name(pool, acc, "uwa")).id == school.id
    other, _ = await people(pool)
    assert await T.get_place(pool, other, school.id) is None
    for i in range(19):
        await T.add_place(pool, acc, name=f"地方{i}", lat=0, lon=0)
    with pytest.raises(ValueError):
        await T.add_place(pool, acc, name="第 21 个", lat=0, lon=0)


async def test_create_three_boxes_and_clock(pool):
    acc, comp = await people(pool)
    plain = await T.create(pool, acc, comp, what="买牛奶", now=NOW)
    assert plain.shape is None and await pool.fetchval("SELECT count(*) FROM clocks WHERE todo_id = $1", plain.id) == 0
    hw = await T.create(pool, acc, comp, what="写作业", shape="at", spec={"time": "15:00", "days": [1]}, now=NOW)
    nxt = await pool.fetchval("SELECT next_at FROM clocks WHERE todo_id = $1 AND kind = 'todo'", hw.id)
    assert nxt == datetime(2026, 10, 6, 7, 0, tzinfo=timezone.utc)                     # 下周二 15:00 新加坡
    school = await T.add_place(pool, acc, name="学校", lat=0, lon=0)
    buy = await T.create(pool, acc, comp, what="买东西", place_id=school.id, place_on="leave", now=NOW)
    assert (buy.place_id, buy.place_on) == (school.id, "leave")
    with pytest.raises(ValueError):
        await T.create(pool, acc, comp, what="x", place_id=school.id, now=NOW)        # 没选到了还是离开
    with pytest.raises(ValueError):
        await T.create(pool, acc, comp, what="  ", now=NOW)
    with pytest.raises(ValueError):
        await T.create(pool, acc, comp, what="x", shape="once", spec={"at": "2026-09-30 10:00"}, now=NOW)   # 过了
    with pytest.raises(ValueError):
        await T.create(pool, acc, comp, what="x", shape="every", spec={"every_min": 60}, now=NOW)
    assert T.describe_when("at", hw.spec, TZ_SG) == "每周二 15:00"
    assert T.describe_when("at", {"time": "08:00", "days": []}, TZ_SG) == "每天 08:00"
    assert T.describe_when("once", {"at": "2026-10-03T06:00:00+00:00"}, TZ_SG) == "10/3 14:00"
    moved = await T.update(pool, acc, hw.id, spec={"time": "16:00", "days": [1, 3]}, now=NOW)
    assert moved.spec == {"time": "16:00", "days": [1, 3]}
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE todo_id = $1", hw.id) == 1          # 重挂不留旧的
    assert await T.delete(pool, acc, hw.id)
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE todo_id = $1", hw.id) == 0


async def test_done_is_per_period(pool):
    acc, comp = await people(pool)
    once = await T.create(pool, acc, comp, what="交表", shape="once", spec={"at": "2026-10-03 09:00"}, now=NOW)
    daily = await T.create(pool, acc, comp, what="吃药", shape="at", spec={"time": "21:00", "days": []}, now=NOW)
    weekly = await T.create(pool, acc, comp, what="写作业", shape="at", spec={"time": "15:00", "days": [1, 3]}, now=NOW)
    once = await T.set_done(pool, acc, once.id, True, NOW)
    assert T.is_done(once, TODAY + timedelta(days=30))
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE todo_id = $1", once.id) == 0       # 一次性打勾收钟
    daily = await T.set_done(pool, acc, daily.id, True, NOW)
    assert T.is_done(daily, TODAY) and not T.is_done(daily, TODAY + timedelta(days=1))
    weekly = await T.set_done(pool, acc, weekly.id, True, NOW)                                        # 周四打勾
    assert T.is_done(weekly, date(2026, 10, 4)) and not T.is_done(weekly, date(2026, 10, 5))          # 周日还算、下周一不算
    once = await T.set_done(pool, acc, once.id, False, NOW)
    assert not T.is_done(once, TODAY) and await pool.fetchval("SELECT count(*) FROM clocks WHERE todo_id = $1", once.id) == 1


async def test_adopt_user_clocks(pool):
    acc, comp = await people(pool)
    at = datetime(2026, 10, 2, 0, 0, tzinfo=timezone.utc)
    c = await clock_store.add_clock(pool, acc, comp, kind="user", shape="once", spec={"at": at.isoformat()},
                                    note="交房租", next_at=at)
    await clock_store.add_clock(pool, acc, comp, kind="self", shape="once", spec={"at": at.isoformat()}, note="问问", next_at=at)
    assert await T.adopt_user_clocks(pool) == 1
    [t] = await T.list_all(pool, acc)
    assert (t.what, t.shape) == ("交房租", "once")
    row = await pool.fetchrow("SELECT kind, todo_id, next_at FROM clocks WHERE id = $1", c.id)
    assert (row["kind"], row["todo_id"], row["next_at"]) == ("todo", t.id, at)
    assert await T.adopt_user_clocks(pool) == 0
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'self'") == 1
