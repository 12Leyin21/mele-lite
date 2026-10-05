import importlib

from memory import store
from memory.config import MemoryConfig
from memory.embed import FakeEmbedder
from memory.rerank import MapReranker

# memory.recall 这个名字被对外同名函数占了，这里要的是模块本身
recall = importlib.import_module("memory.recall")

E = FakeEmbedder()


async def test_reranker_decides_tiers(pool, user_a):
    good = "小满对芒果过敏，吃了嘴唇会肿"
    fake_friend = "小满喜欢芒果色的裙子"          # 向量上也像，但其实不相关
    await store.remember(pool, E, user_a, good)
    await store.remember(pool, E, user_a, fake_friend)
    rr = MapReranker({good: 0.9, fake_friend: 0.001})
    cfg = MemoryConfig(rerank_prefilter_sim=0.1)   # 让两条都进精排
    r = await recall.recall(pool, E, user_a, "今天吃芒果冰沙会过敏吗", reranker=rr, cfg=cfg)
    assert [m.content for m in r.full] == [good]
    assert r.lines == []


async def test_reranker_line_tier_and_order(pool, user_a):
    a = "年糕是一只四岁的橘猫"
    b = "年糕上周刚打了疫苗"
    await store.remember(pool, E, user_a, a)
    await store.remember(pool, E, user_a, b)
    rr = MapReranker({a: 0.2, b: 0.3})
    cfg = MemoryConfig(rerank_prefilter_sim=0.05)
    r = await recall.recall(pool, E, user_a, "年糕今天一直打喷嚏", reranker=rr, cfg=cfg)
    assert r.full == []
    assert [l.snippet for l in r.lines] == [b, a]      # 精排分高的在前


async def test_no_reranker_behaves_like_before(pool, user_a):
    await store.remember(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    r = await recall.recall(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    assert len(r.full) == 1


class BrokenReranker:
    def score(self, query, docs):
        raise RuntimeError("down")


async def test_reranker_down_falls_back_to_thresholds(pool, user_a):
    await store.remember(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    r = await recall.recall(pool, E, user_a, "小满对芒果过敏，吃了嘴唇会肿", reranker=BrokenReranker())
    assert len(r.full) == 1


async def test_rerank_thresholds_follow_level(pool, user_a):
    doc = "小满对芒果过敏，吃了嘴唇会肿"
    await store.remember(pool, E, user_a, doc)
    rr = MapReranker({doc: 0.4})
    cfg = MemoryConfig(rerank_prefilter_sim=0.05)
    got = {}
    for level in ("light", "medium", "rich"):
        r = await recall.recall(pool, E, user_a, "今天吃芒果冰沙会过敏吗", level=level, reranker=rr, cfg=cfg)
        got[level] = "full" if r.full else "line" if r.lines else "none"
    assert got == {"light": "line", "medium": "line", "rich": "full"}


class Tracking(MapReranker):
    def __init__(self, scores):
        super().__init__(scores)
        self.seen: list[str] = []

    def score(self, query, docs):
        self.seen += docs
        return super().score(query, docs)


async def test_sure_candidates_skip_rerank_only_gray_zone_is_read(pool, user_a):
    """09-28 灰区复判：很有把握的直接放行，不等精排；只有门槛附近的才读。"""
    sure = "小满对芒果过敏，吃了嘴唇会肿"
    await store.remember(pool, E, user_a, sure)
    rr = Tracking({sure: 0.0})                           # 精排要是读了它就会判不相关
    r = await recall.recall(pool, E, user_a, sure, reranker=rr)
    assert [m.content for m in r.full] == [sure] and rr.seen == []


async def test_gray_zone_follows_level(pool, user_a):
    """细读的候选范围跟着档位走（以前固定 z 2.4 / 相似度 0.55，三档一个样）。"""
    doc = "小满对芒果过敏，吃了嘴唇会肿"
    await store.remember(pool, E, user_a, doc)
    lows = {}
    for level in ("light", "rich"):
        lo, _ = recall.gray_bounds(recall.LEVELS[level], small=True, keyword=False, cfg=MemoryConfig())
        lows[level] = lo
    assert lows["light"] > lows["rich"]


class SlowReranker:
    def score(self, query, docs):
        import time
        time.sleep(3)
        return [1.0] * len(docs)


async def test_slow_reranker_times_out_to_thresholds(pool, user_a, monkeypatch):
    monkeypatch.setattr(recall, "RERANK_TIMEOUT", 0.2)
    doc = "小满对芒果过敏，吃了嘴唇会肿"
    await store.remember(pool, E, user_a, doc)
    cfg = MemoryConfig(rerank_prefilter_sim=0.05)
    r = await recall.recall(pool, E, user_a, "今天吃芒果冰沙会过敏吗", reranker=SlowReranker(), cfg=cfg)
    assert r is not None                                  # 不卡住，照复判前的门槛走
