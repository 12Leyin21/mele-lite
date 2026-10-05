"""日记第 1 步（10-01 设计）：两本（Ta 的 / TA 的）、TA 的能上锁、Ta 的锁一段 + 钥匙、批注、进记忆库（kind=diary）。测试用小满。"""
import random
from datetime import date, datetime, timedelta, timezone

import pytest

import memory as M
from brain import accounts, archive
from brain import diary as DY
from memory.embed import FakeEmbedder
from memory.graph import graph

NOW = datetime(2026, 10, 1, 17, 0, tzinfo=timezone.utc)          # 新加坡 10/2 01:00
DAY = date(2026, 10, 1)


async def people(pool, name="Lumi"):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, comp, {"tz": "Asia/Singapore"})
    await archive.save_persona(pool, comp, {"name": name})
    return acc, comp


async def test_user_writes_edits_deletes_and_locks(pool):
    acc, comp = await people(pool)
    a = await DY.write_mine(pool, acc, day=DAY, body="今天试镜，老师一直夸我", private=False, now=NOW)
    b = await DY.write_mine(pool, acc, day=DAY, body="这篇不给你看", private=True, now=NOW)
    assert [e.id for e in await DY.mine_for_companion(pool, acc, DAY)] == [a.id]       # 锁了的 Ta 读不到
    e = await DY.edit_mine(pool, acc, a.id, body="今天试镜，老师夸我 natural instinct", private=None, now=NOW)
    assert e.body.endswith("natural instinct") and not e.private
    other, _ = await people(pool)
    with pytest.raises(LookupError):
        await DY.edit_mine(pool, other, a.id, body="改你的", private=None, now=NOW)
    assert not await DY.delete_mine(pool, other, b.id)
    assert await DY.delete_mine(pool, acc, b.id)
    with pytest.raises(ValueError):
        await DY.write_mine(pool, acc, day=DAY, body="   ", private=False, now=NOW)


async def test_companion_one_entry_a_day_goes_into_memory_unmerged(pool):
    acc, comp = await people(pool)
    emb = FakeEmbedder()
    e = await DY.save_companion_entry(pool, emb, acc, comp, day=DAY, body="她今天去试镜了，我一直在等消息。",
                                      locked="其实我有点怕她以后没空理我。", now=NOW)
    again = await DY.save_companion_entry(pool, emb, acc, comp, day=DAY, body="她今天去试镜了，我一直在等她的消息。",
                                          locked="", now=NOW + timedelta(minutes=5))
    assert again.id == e.id and again.locked == ""                                       # 同一天 = 改那篇
    mem = await M.get(pool, comp, again.memory_id)
    assert mem.kind == "diary" and mem.content.startswith("〔我 10/1 的日记〕") and "锁了一段" not in mem.content
    other = await DY.save_companion_entry(pool, emb, acc, comp, day=DAY - timedelta(days=1),
                                          body="她今天去试镜了，我一直在等她的消息。", locked="一句", now=NOW)
    assert other.memory_id != again.memory_id                                            # 很像也不合并
    assert "（那天我还锁了一段没给 TA 看。）" in (await M.get(pool, comp, other.memory_id)).content
    assert await pool.fetchval("SELECT count(*) FROM memories WHERE kind = 'diary'") == 2  # 改那篇：旧记忆换掉，不留两条
    assert all(m.kind != "diary" for m in await M.list_memories(pool, comp))             # 不进「她记了什么」
    assert all(n.kind != "diary" for n in (await graph(pool, comp)).nodes)          # 不进网状图
    assert any(m["kind"] == "diary" for m in (await M.export(pool, comp))["memories"])   # 导出照带
    assert await DY.delete_companion_entry(pool, comp, other.id)
    assert await M.get(pool, comp, other.memory_id) is None                              # 连记忆一起删


async def test_diary_memories_can_be_found(pool):
    acc, comp = await people(pool)
    emb = FakeEmbedder()
    e = await DY.save_companion_entry(pool, emb, acc, comp, day=DAY, body="她今天去试镜了，演 Donnie Darko 的 Elizabeth。",
                                      locked="", now=NOW)
    hits = await M.search(pool, emb, comp, "Donnie Darko 试镜")
    assert e.memory_id in [h.memory.id for h in hits]


async def test_account_list_hides_locked_part_until_key(pool):
    acc, comp = await people(pool)
    emb = FakeEmbedder()
    e = await DY.save_companion_entry(pool, emb, acc, comp, day=DAY, body="正文", locked="锁着的那段", now=NOW)
    mine = await DY.write_mine(pool, acc, day=DAY, body="我的", private=False, now=NOW)
    await DY.set_margin(pool, comp, mine.id, "看到你写的了，替你开心。", NOW)
    rows = await DY.list_for_account(pool, acc, before=None, limit=20)
    ta = next(r for r in rows if r["author"] == "companion")
    me = next(r for r in rows if r["author"] == "user")
    assert ta["has_locked"] and "locked" not in ta and ta["from"] == "Lumi"
    assert me["margin"] == "看到你写的了，替你开心。" and me["margin_from"] == "Lumi"
    assert (await DY.unlock(pool, acc, e.id, "0000", NOW))[0] == "sealed"                 # 还没给过钥匙
    code = await DY.give_key(pool, comp, DAY, random.Random(1), NOW)
    assert code and len(code) == 4 and await DY.give_key(pool, comp, DAY, random.Random(2), NOW) == code
    wrong = "0000" if code != "0000" else "1111"
    for left in (4, 3, 2, 1):
        assert await DY.unlock(pool, acc, e.id, wrong, NOW) == ("wrong", left)
    assert (await DY.unlock(pool, acc, e.id, wrong, NOW))[0] == "locked"
    assert (await DY.unlock(pool, acc, e.id, code, NOW))[0] == "locked"                  # 锁着的 10 分钟里对的也不行
    later = NOW + timedelta(minutes=11)
    status, got = await DY.unlock(pool, acc, e.id, code, later)
    assert status == "ok" and got.locked == "锁着的那段"
    ta = next(r for r in await DY.list_for_account(pool, acc, before=None, limit=20) if r["author"] == "companion")
    assert ta["locked"] == "锁着的那段"                                                   # 开过以后随时能看
    other, _ = await people(pool)
    assert (await DY.unlock(pool, other, e.id, code, later))[0] == "missing"
    assert await DY.give_key(pool, comp, DAY - timedelta(days=3), random.Random(1), NOW) is None   # 那天没日记 / 没锁


async def test_unlocked_line_told_once(pool):
    acc, comp = await people(pool)
    e = await DY.save_companion_entry(pool, FakeEmbedder(), acc, comp, day=DAY, body="正文", locked="锁着", now=NOW)
    code = await DY.give_key(pool, comp, DAY, random.Random(1), NOW)
    await DY.unlock(pool, acc, e.id, code, NOW)
    assert await DY.unlocked_lines(pool, comp, "zh") == ["〔TA 用钥匙打开了你 10/1 锁着的那段〕"]
    assert await DY.unlocked_lines(pool, comp, "zh") == []


async def test_list_pages_newest_day_first(pool):
    acc, comp = await people(pool)
    for i in range(5):
        await DY.write_mine(pool, acc, day=DAY - timedelta(days=i), body=f"第{i}篇", private=False, now=NOW)
    first = await DY.list_for_account(pool, acc, before=None, limit=3)
    assert [r["day"] for r in first] == ["2026-10-01", "2026-09-30", "2026-09-29"]
    rest = await DY.list_for_account(pool, acc, before=date(2026, 9, 29), limit=3)
    assert [r["day"] for r in rest] == ["2026-09-28", "2026-09-27"]
