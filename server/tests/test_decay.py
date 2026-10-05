from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest

from memory.config import MemoryConfig
from memory.decay import weight
from memory.models import Memory

NOW = datetime(2026, 9, 26, tzinfo=timezone.utc)


def mem(**kw) -> Memory:
    base = dict(
        id=1, user_id=uuid4(), kind="memory", content="x", importance=10, valence=0.0,
        arousal=0.0, tags=[], resolved=True, created_at=NOW, updated_at=NOW,
        last_recalled_at=None, recall_count=0,
    )
    base.update(kw)
    return Memory(**base)


def test_fresh_memory_weight_is_importance_over_ten():
    assert weight(mem(importance=7), NOW) == pytest.approx(0.7)


def test_half_life_halves_weight():
    m = mem(importance=4, created_at=NOW - timedelta(days=30))
    assert weight(m, NOW) == pytest.approx(0.2)


def test_unresolved_decays_slower():
    old = NOW - timedelta(days=30)
    assert weight(mem(importance=4, created_at=old, resolved=False), NOW) == pytest.approx(0.4 * 0.5 ** 0.5)


def test_being_recalled_does_not_change_weight():
    # 10-01 起：被想起不加分、不重置时钟（常聊的事会越滚越重，把别的要紧事压下去）
    old = NOW - timedelta(days=30)
    plain = mem(importance=4, created_at=old)
    recalled = mem(importance=4, created_at=old, last_recalled_at=NOW, recall_count=20)
    assert weight(recalled, NOW) == pytest.approx(weight(plain, NOW)) == pytest.approx(0.2)


@pytest.mark.parametrize("kind", ["core", "person"])
def test_core_and_person_never_decay(kind):
    m = mem(kind=kind, created_at=NOW - timedelta(days=3000))
    assert weight(m, NOW) == pytest.approx(1.0)


def test_emotion_boost():
    cfg = MemoryConfig(emotion_boost=0.5)
    m = mem(importance=10, arousal=1.0)
    assert weight(m, NOW, cfg) == pytest.approx(1.5)


def test_important_old_memory_outranks_trivial_often_recalled_one():
    important = mem(importance=9, created_at=NOW - timedelta(days=60))
    trivial = mem(importance=3, created_at=NOW - timedelta(days=60), last_recalled_at=NOW, recall_count=50)
    assert weight(important, NOW) > weight(trivial, NOW)


def test_important_memories_fade_slower():
    # 10-01：淡得多快跟着重要性走，要紧的事过很久还在上面
    old = NOW - timedelta(days=60)
    w = {i: weight(mem(importance=i, created_at=old), NOW) / (i / 10) for i in (3, 5, 7, 9, 10)}
    assert w[3] < w[5] < w[7] < w[9] < w[10]


def test_old_important_memory_outranks_fresh_trivial_one():
    important = mem(importance=9, created_at=NOW - timedelta(days=90))
    trivial = mem(importance=3, created_at=NOW - timedelta(days=7))
    assert weight(important, NOW) > weight(trivial, NOW)


def test_top_importance_barely_fades_in_a_year():
    m = mem(importance=10, created_at=NOW - timedelta(days=365))
    assert weight(m, NOW) > 0.5


def test_rewrite_resets_the_clock():
    m = mem(importance=4, created_at=NOW - timedelta(days=300), rewritten_at=NOW - timedelta(days=30))
    assert weight(m, NOW) == pytest.approx(0.2)
