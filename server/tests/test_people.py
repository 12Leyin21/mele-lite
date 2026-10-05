import pytest

from memory import people
from memory.embed import FakeEmbedder

E = FakeEmbedder()


async def test_upsert_creates_then_updates(pool, user_a):
    p = await people.upsert_person(pool, E, user_a, "秀兰", relation="妈妈",
                                   facts="生日 3 月 14 日，喜欢君子兰", aliases=["妈", "我妈"])
    assert p.kind == "person" and p.name == "秀兰" and p.relation == "妈妈"
    assert p.content == "生日 3 月 14 日，喜欢君子兰"          # content 就是「要记得」
    assert p.created_by == "user" and p.updated_by == "user"
    p2 = await people.upsert_person(pool, E, user_a, "秀兰", facts="生日 3 月 14 日；最近在学太极",
                                    aliases=["老妈"])
    assert p2.id == p.id
    assert p2.content == "生日 3 月 14 日；最近在学太极"
    assert p2.relation == "妈妈"                       # 没给就不改
    assert set(p2.aliases) == {"妈", "我妈", "老妈"}


async def test_upsert_is_case_insensitive(pool, user_a):
    a = await people.upsert_person(pool, E, user_a, "Dr. Chen", facts="导师")
    b = await people.upsert_person(pool, E, user_a, "dr. chen", facts="导师，评价很好")
    assert a.id == b.id


async def test_empty_name_rejected(pool, user_a):
    with pytest.raises(ValueError):
        await people.upsert_person(pool, E, user_a, "  ")


async def test_aliases_from_string_and_limits(pool, user_a):
    p = await people.upsert_person(pool, E, user_a, "阿杰", aliases="杰哥，阿杰、AJ/ 杰\n杰哥")
    assert p.aliases == ["杰哥", "阿杰", "AJ", "杰"]
    long = await people.upsert_person(pool, E, user_a, "名" * 100, facts="事" * 2000,
                                      aliases=[f"别名{i}" for i in range(30)])
    assert len(long.name) == 40 and len(long.content) == 600 and len(long.aliases) == 12


async def test_ai_writes_impression_but_never_overwrites_user_facts(pool, user_a):
    await people.upsert_person(pool, E, user_a, "秀兰", relation="妈妈", facts="生日 3 月 14 日")
    p = await people.upsert_person(pool, E, user_a, "秀兰", relation="阿姨", facts="生日 5 月",
                                   impression="说话很温柔，总惦记她吃没吃饭", by="ai")
    assert p.relation == "妈妈" and p.content == "生日 3 月 14 日"   # 用户写的，它改不动
    assert p.impression == "说话很温柔，总惦记她吃没吃饭"
    assert p.created_by == "user" and p.updated_by == "ai"


async def test_ai_can_fill_empty_fields_and_create_cards(pool, user_a):
    p = await people.upsert_person(pool, E, user_a, "小雨", by="ai", relation="室友", facts="爱喝奶茶")
    assert p.created_by == "ai" and p.relation == "室友" and p.content == "爱喝奶茶"
    p2 = await people.upsert_person(pool, E, user_a, "小雨", by="ai", facts="爱喝奶茶，不吃辣")
    assert p2.content == "爱喝奶茶，不吃辣"          # 它自己写的，它能改


async def test_update_person_replaces_given_fields(pool, user_a):
    p = await people.upsert_person(pool, E, user_a, "秀兰", aliases=["妈", "我妈"], relation="妈妈",
                                   impression="温柔")
    u = await people.update_person(pool, E, user_a, p.id, name="秀兰阿姨", aliases=["我妈"],
                                   impression="")
    assert u.name == "秀兰阿姨" and u.aliases == ["我妈"] and u.impression == ""
    assert u.relation == "妈妈"
    assert await people.update_person(pool, E, user_a, 99999, name="x") is None
    with pytest.raises(ValueError):
        await people.update_person(pool, E, user_a, p.id, name=" ")


async def test_match_by_name_or_alias(pool, user_a):
    await people.upsert_person(pool, E, user_a, "秀兰", relation="妈妈", aliases=["我妈"])
    await people.upsert_person(pool, E, user_a, "阿杰", relation="好朋友")
    await people.upsert_person(pool, E, user_a, "Dr. Chen", relation="导师")
    names = lambda ms: [m.name for m in ms]
    assert names(await people.match_people(pool, user_a, "我妈今天打电话来了")) == ["秀兰"]
    # 按在话里出现的先后排
    assert names(await people.match_people(pool, user_a, "跟 dr. chen 和阿杰吃饭")) == ["Dr. Chen", "阿杰"]
    assert names(await people.match_people(pool, user_a, "跟阿杰和 dr. chen 吃饭")) == ["阿杰", "Dr. Chen"]
    assert await people.match_people(pool, user_a, "今天天气不错") == []


async def test_match_english_whole_word_only(pool, user_a):
    await people.upsert_person(pool, E, user_a, "Oak")
    assert await people.match_people(pool, user_a, "let it soak overnight") == []
    assert [m.name for m in await people.match_people(pool, user_a, "Oak's birthday is soon")] == ["Oak"]


async def test_match_exclude_and_limit(pool, user_a):
    ids = {}
    for n in ["甲一", "乙二", "丙三", "丁四"]:
        ids[n] = (await people.upsert_person(pool, E, user_a, n)).id
    text = "甲一乙二丙三丁四"
    assert [m.name for m in await people.match_people(pool, user_a, text)] == ["甲一", "乙二", "丙三"]
    got = await people.match_people(pool, user_a, text, exclude={ids["甲一"]})
    assert [m.name for m in got] == ["乙二", "丙三", "丁四"]


async def test_list_people_sorted(pool, user_a):
    await people.upsert_person(pool, E, user_a, "b")
    await people.upsert_person(pool, E, user_a, "a")
    assert [p.name for p in await people.list_people(pool, user_a)] == ["a", "b"]


async def test_render(pool, user_a):
    p = await people.upsert_person(pool, E, user_a, "秀兰", aliases=["我妈", "秀兰"], relation="妈妈",
                                   facts="生日 3 月 14 日")
    p = await people.upsert_person(pool, E, user_a, "秀兰", impression="很温柔", by="ai")
    assert people.render_person(p) == "〔人物卡 · 秀兰（也叫 我妈）〕是谁：妈妈｜要记得：生日 3 月 14 日｜你的印象：很温柔"
    assert people.render_person(p, lang="en") == (
        "[Person card · 秀兰 (aka 我妈)] Who: 妈妈 | Remember: 生日 3 月 14 日 | Your impression: 很温柔")
    bare = await people.upsert_person(pool, E, user_a, "阿杰")
    assert people.render_person(bare) == "〔人物卡 · 阿杰〕"


async def test_linked_memories_mention_the_person_and_favor_recent(pool, user_a):
    import random
    from datetime import datetime, timedelta, timezone
    from memory import store
    from memory.config import MemoryConfig
    from memory.people import linked_memories
    now = datetime(2026, 9, 27, tzinfo=timezone.utc)
    mu = await people.upsert_person(pool, E, user_a, "Mu", relation="男朋友")
    old = (await store.remember(pool, E, user_a, "去年和Mu去了大洋路看海", now=now - timedelta(days=300))).memory
    new = (await store.remember(pool, E, user_a, "昨天和Mu在家看了星际穿越", now=now - timedelta(days=1))).memory
    await store.remember(pool, E, user_a, "小满对芒果过敏", now=now)
    await store.remember(pool, E, user_a, "Mumbai 的咖喱很辣", now=now)                 # 英文名要整词，不算
    one = MemoryConfig(person_linked_max=1)
    picks = [ (await linked_memories(pool, user_a, mu, now=now, rng=random.Random(i), cfg=one))[0].id for i in range(200)]
    assert set(picks) == {old.id, new.id} and 150 < picks.count(new.id) < 200          # 越新越容易，老的也还有机会
    both = await linked_memories(pool, user_a, mu, now=now, rng=random.Random(0))
    assert {m.id for m in both} == {old.id, new.id}                                     # 不相干的不挑
    assert await linked_memories(pool, user_a, mu, now=now, exclude={old.id, new.id}) == []
    assert [m.id for m in await linked_memories(pool, user_a, mu, now=now, before=now - timedelta(days=100))] == [old.id]
