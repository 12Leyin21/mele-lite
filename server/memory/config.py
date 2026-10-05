"""所有可调参数放这里，评测时改这里，不在代码里写死数。"""
from dataclasses import dataclass


@dataclass(frozen=True)
class MemoryConfig:
    # 淡去
    half_life_days: float = 30.0          # 小事（重要性 ≤4）：记下多少天后分量减半
    # 10-01：越要紧淡得越慢——半衰期 × 这个倍数（重要性 10 约 16 个月才减半，9 约 10 个月，7 约 4 个月）
    importance_half_life_mult: tuple = ((10, 16.0), (9, 10.0), (8, 6.0), (7, 4.0), (6, 2.5), (5, 1.6))
    unresolved_half_life_mult: float = 2.0  # 没了结的事忘得慢一倍
    emotion_boost: float = 0.5            # 情绪越强越不容易忘：× (1 + 0.5 × 强度)
    # 搜索
    weight_floor: float = 0.5             # 排序分 = 融合分 × (0.5 + 当前分量)，老记忆不会被压到零
    search_candidates: int = 30           # 每一路先各取多少条
    rrf_k: int = 60                       # 排名融合的常数
    # 合并
    merge_threshold: float = 0.92         # 跟某条已有记忆向量这么像，就当同一件事合并
    similar_guard: float = 0.75           # 像到这个数（但不到合并线）：大脑的「记住」先不存，让模型自己决定改旧的还是另存
    rare_guard_sim: float = 0.60          # 没到上一条线，但像到这个数、又共用一个少见的词，也先拦下来问（09-27 星际穿越记了两遍，0.674）
    rare_max_df: int = 1                  # 「少见」= 这个词在 TA 别的记忆里最多出现这么多条（测试库 14 条里只拦对了那一对）
    # 浮现
    min_for_z: int = 20                   # 记忆少于这个数时 z 分不稳，改用绝对相似度
    max_full: int = 2                     # 一轮最多整条塞几条
    max_lines: int = 3                    # 一轮最多放几行摘要
    snippet_chars: int = 80               # 摘要行多长
    # 精排（reranker）：先用宽一点的门槛放一批候选进来，再让 reranker 逐条打分定档
    rerank_pool: int = 8                  # 最多送几条去精排
    # 09-28 灰区复判：很有把握的直接放行，只把门槛附近的交给精排（大部分句子不用等，细读才能默认开）。
    # 灰区 = [摘要门槛 - gray_margin, 整条门槛 + sure_margin)，跟着档位走；再往上是「很有把握」
    rerank_gray_margin_z: float = 0.8
    rerank_sure_margin_z: float = 1.0
    rerank_gray_margin_sim: float = 0.06  # 记忆太少时按相似度
    rerank_sure_margin_sim: float = 0.06
    rerank_prefilter_z: float | None = None     # 手动压低灰区下沿（测试用）；None = 跟档位
    rerank_prefilter_sim: float | None = None
    # 人物卡（照之前自用的 App）
    person_name_max: int = 40
    person_alias_max: int = 12
    person_field_max: int = 600           # 是谁 / 要记得 / 印象，每段最多这么长
    person_match_max: int = 3             # 一句话最多递几张卡
    person_linked_max: int = 2            # 每张卡顺带递几条跟这个人有关的记忆（Tilia 09-27）
    person_linked_age_scale_days: float = 30.0   # 挑的时候越新越容易：权重 1/(1+天数/30)，昨天的 vs 300 天前的约 11:1
    # 便利贴
    sticky_max_chars: int = 300


DEFAULT = MemoryConfig()
