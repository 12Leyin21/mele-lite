"""当前分量：这条记忆此刻有多「重」。纯计算，不碰数据库。

分量 = 重要性/10 × 时间衰减 × 情绪加成
- 时间衰减：从创建那天（内容改写/合并过就从最后一次改写）算起，按半衰期指数衰减；越要紧半衰期越长（见 config 的
  importance_half_life_mult），没了结的事再翻倍；钉住的核心、人物卡、「关于 TA」不衰减。
- 10-01 起被想起不算分、也不重置时钟：以前「常被想起的更重」会滚雪球，常聊的那件事
  越来越靠前，别的要紧事反而沉底。last_recalled_at / recall_count 照记，只给页面看。
"""
from datetime import datetime

from .config import DEFAULT, MemoryConfig
from .models import Memory


def half_life(m: Memory, cfg: MemoryConfig = DEFAULT) -> float:
    mult = dict(cfg.importance_half_life_mult).get(m.importance, 1.0)
    return cfg.half_life_days * mult * (1.0 if m.resolved else cfg.unresolved_half_life_mult)


def weight(m: Memory, now: datetime, cfg: MemoryConfig = DEFAULT) -> float:
    base = m.importance / 10.0
    if m.kind in ("core", "person", "about"):
        time_factor = 1.0
    else:
        anchor = max(m.created_at, m.rewritten_at) if m.rewritten_at else m.created_at
        days = max(0.0, (now - anchor).total_seconds() / 86400.0)
        time_factor = 0.5 ** (days / half_life(m, cfg))
    emotion = 1.0 + cfg.emotion_boost * m.arousal
    return base * time_factor * emotion
