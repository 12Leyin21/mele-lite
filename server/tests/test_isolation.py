"""A 的东西 B 永远碰不到：看不到、搜不到、浮现不到、改不了、删不掉、导不出、清不掉。"""
import memory as M

E = M.FakeEmbedder()


async def test_everything_is_per_user(pool, user_a, user_b):
    m = (await M.remember(pool, E, user_a, "只属于 A 的秘密：芒果过敏")).memory
    p = await M.upsert_person(pool, E, user_a, "秀兰", aliases=["我妈"])
    await M.set_sticky(pool, user_a, "A 的便利贴")

    assert await M.get(pool, user_b, m.id) is None
    assert await M.list_memories(pool, user_b) == []
    assert await M.search(pool, E, user_b, "芒果过敏") == []
    r = await M.recall(pool, E, user_b, "只属于 A 的秘密：芒果过敏")
    assert r.full == [] and r.lines == [] and r.people == []
    assert await M.match_people(pool, user_b, "我妈来了") == []
    assert await M.list_people(pool, user_b) == []
    assert await M.get_sticky(pool, user_b) == ""
    assert await M.update(pool, E, user_b, m.id, content="被 B 改了") is None
    assert await M.pin(pool, user_b, m.id) is None
    assert await M.resolve(pool, user_b, m.id) is None
    assert await M.delete(pool, user_b, m.id) is False
    assert (await M.export(pool, user_b)) == {"memories": [], "sticky": ""}
    assert (await M.graph(pool, user_b)).nodes == []
    assert await M.wipe(pool, user_b) == 0

    # A 的都还在
    assert (await M.get(pool, user_a, m.id)).content == "只属于 A 的秘密：芒果过敏"
    assert [x.id for x in await M.list_people(pool, user_a)] == [p.id]
    assert await M.get_sticky(pool, user_a) == "A 的便利贴"


async def test_merge_never_crosses_users(pool, user_a, user_b):
    await M.remember(pool, E, user_a, "一模一样的一句话")
    r = await M.remember(pool, E, user_b, "一模一样的一句话")
    assert not r.merged
