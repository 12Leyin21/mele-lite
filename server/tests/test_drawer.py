"""抽屉（09-28 远事 + 抽屉第 4 步）：放信、它自己翻、给钥匙、烧掉、TA 的列表不漏、拆信（到日子 / 密码 / 错次锁）。测试用小满。"""
import random
from datetime import date, datetime, timedelta, timezone

import pytest

from brain import accounts, archive
from brain import drawer as D

NOW = datetime(2026, 9, 28, 4, 0, tzinfo=timezone.utc)          # 新加坡 9/28 12:00
TODAY = date(2026, 9, 28)


async def people(pool, name="Lumi"):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, comp, {"tz": "Asia/Singapore"})
    await archive.save_persona(pool, comp, {"name": name})
    return acc, comp


def test_openable_and_code():
    sealed = D.Letter(id=1, account_id=None, companion_id=None, title="", content="", unlock_at=None, code="",
                      code_fails=0, code_locked_until=None, keyed_at=None, opened_at=None, notified_at=None,
                      told_opened=False, burned_at=None, created_at=NOW)
    assert not D.openable(sealed, TODAY)
    assert D.openable(D.replace(sealed, unlock_at=TODAY), TODAY)
    assert not D.openable(D.replace(sealed, unlock_at=TODAY + timedelta(days=1)), TODAY)
    assert D.openable(D.replace(sealed, opened_at=NOW), TODAY)
    codes = {D.new_code(random.Random(i)) for i in range(50)}
    assert all(len(c) == 4 and c.isdigit() for c in codes) and len(codes) > 40


async def test_put_mine_and_the_list_never_leaks(pool):
    acc, comp = await people(pool)
    a = await D.put(pool, acc, comp, title="给你的", content="生日快乐，小满", unlock_at=date(2026, 12, 21), now=NOW)
    b = await D.put(pool, acc, comp, title="", content="那天你说的话我一直记着", unlock_at=None, now=NOW)
    assert [x.id for x in await D.mine(pool, comp)] == [b.id, a.id]
    rows = await D.list_for_account(pool, acc, NOW)
    assert [r["id"] for r in rows] == [b.id, a.id]
    for r in rows:
        assert set(r) == {"id", "companion_id", "from", "written_at", "unlock_at", "openable", "opened"}
        assert r["from"] == "Lumi" and not r["openable"] and not r["opened"]
    assert rows[1]["unlock_at"] == "2026-12-21" and rows[0]["unlock_at"] is None


async def test_put_rules(pool):
    acc, comp = await people(pool)
    with pytest.raises(ValueError):
        await D.put(pool, acc, comp, title="", content="  ", unlock_at=None, now=NOW)
    with pytest.raises(ValueError):
        await D.put(pool, acc, comp, title="", content="x", unlock_at=date(2026, 9, 27), now=NOW)
    for i in range(D.MAX_SEALED):
        await D.put(pool, acc, comp, title="", content=str(i), unlock_at=None, now=NOW)
    with pytest.raises(ValueError, match="先烧"):
        await D.put(pool, acc, comp, title="", content="第 31 封", unlock_at=None, now=NOW)
    other, _ = await people(pool)
    with pytest.raises(PermissionError):
        await D.put(pool, other, comp, title="", content="别人的", unlock_at=None, now=NOW)


async def test_opens_on_its_day(pool):
    acc, comp = await people(pool)
    a = await D.put(pool, acc, comp, title="秋天", content="今天风很好", unlock_at=date(2026, 10, 1), now=NOW)
    assert await D.open_letter(pool, acc, a.id, "", NOW) == ("sealed", None)
    day = datetime(2026, 9, 30, 16, 5, tzinfo=timezone.utc)          # 新加坡 10/1 00:05
    status, letter = await D.open_letter(pool, acc, a.id, "", day)
    assert status == "ok" and letter.content == "今天风很好" and letter.opened_at == day
    [row] = await D.list_for_account(pool, acc, day)
    assert row["opened"] and row["openable"] and row["title"] == "秋天"
    again = await D.open_letter(pool, acc, a.id, "", day + timedelta(days=1))
    assert again[0] == "ok" and again[1].opened_at == day                # 第一次拆的时间不变


async def test_key_wrong_codes_and_lock(pool):
    acc, comp = await people(pool)
    a = await D.put(pool, acc, comp, title="", content="偷偷写的", unlock_at=None, now=NOW)
    code = await D.give_key(pool, comp, a.id, random.Random(7), NOW)
    assert code == await D.give_key(pool, comp, a.id, random.Random(99), NOW)      # 再问还是同一串
    wrong = "0000" if code != "0000" else "1111"
    for left in (4, 3, 2, 1):
        assert await D.open_letter(pool, acc, a.id, wrong, NOW) == ("wrong", left)
    status, wait = await D.open_letter(pool, acc, a.id, wrong, NOW)
    assert status == "locked" and wait == 600
    assert (await D.open_letter(pool, acc, a.id, code, NOW + timedelta(minutes=5)))[0] == "locked"   # 锁着对的也不行
    status, letter = await D.open_letter(pool, acc, a.id, code, NOW + timedelta(minutes=11))
    assert status == "ok" and letter.content == "偷偷写的"
    assert (await D.open_letter(pool, acc, a.id, "", NOW + timedelta(minutes=12)))[0] == "ok"        # 开过的不用再输


async def test_burn_and_strangers(pool):
    acc, comp = await people(pool)
    a = await D.put(pool, acc, comp, title="", content="算了", unlock_at=TODAY, now=NOW)
    other, other_comp = await people(pool, "阿澄")
    assert await D.open_letter(pool, other, a.id, "", NOW) == ("missing", None)
    assert await D.give_key(pool, other_comp, a.id, random.Random(1), NOW) is None
    assert not await D.burn(pool, other_comp, a.id, NOW)
    assert await D.burn(pool, comp, a.id, NOW)
    assert await D.list_for_account(pool, acc, NOW) == [] and await D.mine(pool, comp) == []
    assert await D.open_letter(pool, acc, a.id, "", NOW) == ("missing", None)


async def test_one_drawer_for_all_contacts(pool):
    acc, lumi = await people(pool)
    ava = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, ava, {"tz": "Asia/Singapore"})
    await archive.save_persona(pool, ava, {"name": "Ava"})
    await D.put(pool, acc, lumi, title="", content="L", unlock_at=None, now=NOW)
    await D.put(pool, acc, ava, title="", content="A", unlock_at=None, now=NOW + timedelta(minutes=1))
    assert [r["from"] for r in await D.list_for_account(pool, acc, NOW)] == ["Ava", "Lumi"]
