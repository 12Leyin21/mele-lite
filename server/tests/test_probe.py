"""召回哨兵（09-28，召回改造第 3 步）：先听懂这句再去搜；出错退回原句。"""
import importlib
from datetime import date, datetime, timedelta, timezone

from brain import probe as P
from llm.errors import LLMError
from llm.fake import FakeModel
from memory import store
from memory.embed import FakeEmbedder
from memory.models import Probe

recall = importlib.import_module("memory.recall")
E = FakeEmbedder()
NOW = datetime(2026, 9, 28, 12, tzinfo=timezone.utc)


def test_parse_reads_json_even_with_chatter_around_it():
    p = P.parse('好的：{"recall": true, "topic": "年糕打完针回来没精神", "keywords": ["年糕", "疫苗"], '
                '"date_from": "2026-09-21", "date_to": null}', "它回来就一直蔫蔫的")
    assert p.recall and p.topic == "年糕打完针回来没精神" and p.keywords == ("年糕", "疫苗")
    assert p.date_from == p.date_to == date(2026, 9, 21)
    assert P.parse("不是 JSON", "x") is None and P.parse('{"recall": ', "x") is None


def test_forced_phrases_always_recall():
    assert P.parse('{"recall": false, "topic": "", "keywords": []}', "上次我说想去哪看红叶来着").recall
    assert not P.parse('{"recall": false, "topic": "", "keywords": []}', "今天天气不错").recall


async def test_probe_falls_back_to_none_on_error_or_garbage():
    assert await P.probe(FakeModel([LLMError("server", "boom")]), "m", "它呢", []) is None
    assert await P.probe(FakeModel(["我觉得要翻"]), "m", "它呢", []) is None
    m = FakeModel(['{"recall": true, "topic": "年糕", "keywords": ["年糕"]}'])
    got = await P.probe(m, "m", "它呢", ["小满：年糕今天打针了"], today=date(2026, 9, 28))
    assert got.topic == "年糕" and "2026-09-28" in m.requests[0].messages[0].text and "年糕今天打针了" in m.requests[0].messages[0].text


async def test_recall_follows_probe(pool, user_a):
    m = (await store.remember(pool, E, user_a, "年糕上周刚打了疫苗", now=NOW)).memory
    # 哨兵说不用翻：原句再像也不翻
    r = await recall.recall(pool, E, user_a, "年糕上周刚打了疫苗", now=NOW, probe=Probe(recall=False))
    assert r.full == [] and r.lines == []
    # 原句只有代词，哨兵把它说全了：按话题找得到（假向量：话题跟记忆一字不差才像）
    r = await recall.recall(pool, E, user_a, "它呢", now=NOW, probe=Probe(topic="年糕上周刚打了疫苗"))
    assert m.id in [x.id for x in r.full] + [l.memory_id for l in r.lines]


async def test_recall_date_window_falls_back_to_everything(pool, user_a):
    old = (await store.remember(pool, E, user_a, "年糕上周刚打了疫苗", now=NOW - timedelta(days=30))).memory
    p = Probe(topic="年糕上周刚打了疫苗", date_from=date(2026, 9, 21), date_to=date(2026, 9, 21))
    r = await recall.recall(pool, E, user_a, "它呢", now=NOW, probe=p)      # 那几天一条都没有 → 回到全部
    assert old.id in [x.id for x in r.full] + [l.memory_id for l in r.lines]
