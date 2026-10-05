"""浮现（联想）：用户每说一句，自动捞出相关的记忆，分三档——整条 / 一行摘要 / 不放。

怎么判「相关」：拿这句的向量跟这个用户**所有**普通记忆算相似度，再换成标准分（z）——
「这条比这个用户平时的记忆像多少个标准差」。这样记忆多的人、少的人、说中文说英文的，
门槛都稳。关键词也命中的，门槛放低一点（有字面上的实锤）。
记忆太少（< min_for_z）时 z 不稳，改用绝对相似度。
门槛数从之前自用的 App的联想（bge-m3 真数据上校准过）起步，之后用评测集调。
"""
from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from uuid import UUID

import asyncpg
import numpy as np

from . import stopwords, store, words
from .config import DEFAULT, MemoryConfig
from .embed import Embedder, embed_one
from .models import Memory, Probe, RecallLine, RecallResult
from .people import linked_memories, match_people
from .rerank import Reranker
from .search import keyword_ids

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Tier:
    full_z: float     # 光靠向量：z 到这么高 → 整条
    full_zk: float    # 关键词也命中：z 到这么高 → 整条
    line_z: float     # 光靠向量 → 摘要行
    line_zk: float    # 关键词也命中 → 摘要行
    full_sim: float   # 记忆太少时：相似度到这么高 → 整条
    line_sim: float   # 记忆太少时 → 摘要行
    # 细读开着时（09-28 按真分重定，评测集上量的：该想起的原始分 -5~3，不相关的 -11 左右）：
    # 整条 = 模型认为相关（sigmoid(0)=0.5 附近），摘要行 = 不至于不相关，再低就挡掉
    rerank_full: float = 0.50   # 原始分 ≥ 0
    rerank_line: float = 0.011  # 原始分 ≥ -4.5


LEVELS: dict[str, Tier | None] = {
    "off": None,
    "light": Tier(full_z=5.0, full_zk=4.4, line_z=4.2, line_zk=3.6, full_sim=0.78, line_sim=0.70,
                  rerank_full=0.73, rerank_line=0.047),     # 原始分 ≥ 1 / ≥ -3
    "medium": Tier(full_z=4.2, full_zk=3.6, line_z=3.5, line_zk=3.0, full_sim=0.74, line_sim=0.66),
    "rich": Tier(full_z=3.5, full_zk=3.0, line_z=2.8, line_zk=2.4, full_sim=0.70, line_sim=0.62,
                 rerank_full=0.27, rerank_line=0.0025),     # 原始分 ≥ -1 / ≥ -6
}

DEDUP_SIM = 0.82          # 跟这一潮递过的、或者同一轮排在前面的，像到这个数就当同一件事换了件衣服（09-28 量的：
                          # 同一件事换说法 0.886~0.927，相关但不同的事最高 0.745）
DATE_WINDOW_MIN_Z = 3.0    # 日期窗口里最像的一条到这个 z 分才只看窗口，不然回到全库（之前自用的 App 09-28）
KEYWORD_SIM_BONUS = 0.03   # 记忆太少时，关键词命中给相似度加一点

_SMALL_TALK = re.compile(
    r"^(好的?|嗯+|哦+|噢|哈+|嘿+|嘻+|呜+|啊+|行|对|是|好呀|好哦|收到|晚安|早安|么么|亲亲|抱抱|"
    r"ok(ay)?|thanks?|thank you|ok thanks|lol|haha+|yes|no|sure|night|morning)$",
    re.IGNORECASE,
)
_EMOJI = re.compile(r"[\U0001F000-\U0001FAFF☀-➿️]")
_PUNCT = re.compile(r"[\s?？!！~～。.…,，]+")


@dataclass
class Candidate:
    memory: Memory
    sim: float
    z: float
    keyword: bool


def worth_recalling(text: str) -> bool:
    body = _EMOJI.sub("", text or "").strip()
    bare = _PUNCT.sub(" ", body).strip()
    if len(bare.replace(" ", "")) < 5:
        return False
    return not _SMALL_TALK.match(bare)


def zscores(sims: np.ndarray) -> np.ndarray:
    sd = float(sims.std()) or 1e-6
    return (sims - float(sims.mean())) / sd


def classify(c: Candidate, tier: Tier, small: bool) -> str:
    if small:
        s = c.sim + (KEYWORD_SIM_BONUS if c.keyword else 0.0)
        if s >= tier.full_sim:
            return "full"
        return "line" if s >= tier.line_sim else "none"
    if c.z >= (tier.full_zk if c.keyword else tier.full_z):
        return "full"
    return "line" if c.z >= (tier.line_zk if c.keyword else tier.line_z) else "none"


def pick(cands: list[Candidate], tier: Tier, small: bool, already_shown, max_full: int,
         max_lines: int) -> tuple[list[Candidate], list[Candidate]]:
    ordered = sorted(cands, key=lambda c: (c.sim if small else c.z), reverse=True)
    full: list[Candidate] = []
    lines: list[Candidate] = []
    for c in ordered:
        if c.memory.id in already_shown:
            continue
        label = classify(c, tier, small)
        if label == "full" and len(full) < max_full:
            full.append(c)
        elif label in ("full", "line") and len(lines) < max_lines:
            lines.append(c)
    return full, lines


def snippet(text: str, n: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "…"


RERANK_TIMEOUT = 2.0     # 秒：精排这么久没回来就照复判前的门槛走（09-28）


def gray_bounds(tier: Tier, small: bool, keyword: bool, cfg: MemoryConfig) -> tuple[float, float]:
    """这一档的灰区 [下沿, 上沿)：比摘要门槛低一点到比整条门槛高一点。上沿以上是「很有把握」，不读直接放行。"""
    if small:
        lo = tier.line_sim - cfg.rerank_gray_margin_sim
        hi = tier.full_sim + cfg.rerank_sure_margin_sim
        return (min(lo, cfg.rerank_prefilter_sim) if cfg.rerank_prefilter_sim is not None else lo), hi
    lo = (tier.line_zk if keyword else tier.line_z) - cfg.rerank_gray_margin_z
    hi = (tier.full_zk if keyword else tier.full_z) + cfg.rerank_sure_margin_z
    return (min(lo, cfg.rerank_prefilter_z) if cfg.rerank_prefilter_z is not None else lo), hi


async def rerank_pick(query: str, cands: list[Candidate], tier: Tier, small: bool, already_shown,
                      reranker: Reranker, cfg: MemoryConfig) -> tuple[list[Candidate], list[Candidate]]:
    """灰区复判（09-28）：很有把握的直接放行；门槛附近的前几名交给精排，按这一档的精排门槛定档；
    精排出错或超时，灰区照普通门槛（pick）走——不比不开细读差。没有灰区就一次精排都不跑。"""
    ordered = [c for c in sorted(cands, key=lambda c: (c.sim if small else c.z), reverse=True)
               if c.memory.id not in already_shown]
    sure: list[Candidate] = []
    gray: list[Candidate] = []
    for c in ordered:
        lo, hi = gray_bounds(tier, small, c.keyword, cfg)
        v = c.sim + (KEYWORD_SIM_BONUS if small and c.keyword else 0.0) if small else c.z
        if v >= hi:
            sure.append(c)
        elif v >= lo and len(gray) < cfg.rerank_pool:
            gray.append(c)
    full = sure[: cfg.max_full]
    lines = sure[cfg.max_full: cfg.max_full + cfg.max_lines]
    if not gray:
        return full, lines
    try:
        docs = [c.memory.content for c in gray]
        if hasattr(reranker, "ascore"):      # 大模型判读器（brain/judge.py，09-28）：异步，自带超时
            scores = await asyncio.wait_for(reranker.ascore(query, docs), getattr(reranker, "timeout", RERANK_TIMEOUT))
        else:
            scores = await asyncio.wait_for(asyncio.to_thread(reranker.score, query, docs),
                                            RERANK_TIMEOUT if getattr(reranker, "ready", True) else None)   # 冷启动那一句等它加载完
    except Exception as e:
        log.warning("rerank failed or too slow (%s); gray zone falls back to thresholds", type(e).__name__)
        g_full, g_lines = pick(gray, tier, small, already_shown, cfg.max_full - len(full), cfg.max_lines - len(lines))
        return full + g_full, lines + g_lines
    for c, s in sorted(zip(gray, scores), key=lambda x: x[1], reverse=True):
        if s >= tier.rerank_full and len(full) < cfg.max_full:
            full.append(c)
        elif s >= tier.rerank_line and len(lines) < cfg.max_lines:
            lines.append(c)
    return full, lines


def _cosines(xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    xs = xs / np.maximum(np.linalg.norm(xs, axis=1, keepdims=True), 1e-9)
    ys = ys / np.maximum(np.linalg.norm(ys, axis=1, keepdims=True), 1e-9)
    return xs @ ys.T


async def dedup(pool: asyncpg.Pool, user_id: UUID, cands: list[Candidate], shown) -> list[Candidate]:
    """语义去重（09-28，召回改造第 5 步）：冷却只挡「同一条」，这里挡「同一件事换了件衣服」——
    跟这一潮已经递过的像到 DEDUP_SIM 的不递；候选之间也一样，按排名留第一条。"""
    if not cands:
        return cands
    ids = [c.memory.id for c in cands] + [int(i) for i in shown]
    rows = await pool.fetch("SELECT id, embedding FROM memories WHERE user_id = $1 AND id = ANY($2::bigint[]) "
                            "AND embedding IS NOT NULL", user_id, ids)
    vec = {r["id"]: np.asarray(r["embedding"], dtype=np.float32) for r in rows}
    seen_ids = [i for i in (int(x) for x in shown) if i in vec]
    have = [c for c in cands if c.memory.id in vec]
    if not have:
        return cands
    cv = np.stack([vec[c.memory.id] for c in have])
    drop: set[int] = set()
    if seen_ids:
        near_seen = _cosines(cv, np.stack([vec[i] for i in seen_ids])).max(axis=1)
        drop |= {c.memory.id for c, s in zip(have, near_seen) if s >= DEDUP_SIM}
    among = _cosines(cv, cv)
    kept: list[int] = []
    for i, c in enumerate(have):
        if c.memory.id in drop:
            continue
        if any(among[i, j] >= DEDUP_SIM for j in kept):
            drop.add(c.memory.id)
        else:
            kept.append(i)
    return [c for c in cands if c.memory.id not in drop]


async def recall(pool: asyncpg.Pool, embedder: Embedder, user_id: UUID, text: str, *,
                 context: str | None = None, level: str = "medium", already_shown=frozenset(),
                 in_context_since: datetime | None = None, now: datetime | None = None,
                 cfg: MemoryConfig = DEFAULT, reranker: Reranker | None = None,
                 people_owner: UUID | None = None, rng=None, names=(), probe: Probe | None = None) -> RecallResult:
    """names：称呼（它的名字、用户的名字），不进关键词榜（stopwords.py）。
    probe：召回哨兵听懂之后给的（brain/probe.py）。有就按它：要不要翻听它的；原句和话题各算一个向量，
    每条记忆取更像的那个分（之前自用的 App 09-28 教训：只用话题会丢原句的词）；关键词按 稀有词 → 话题 → 原句 退，
    哪一级滤完称呼还有词就用哪一级；说到日期就先看那几天（前后各放宽一天），那几天里最像的一条 z 分不到
    DATE_WINDOW_MIN_Z 就回到全部（之前自用的 App教训：窗口要有退路）。没有 probe（哨兵没开 / 出错）就跟以前一样拿原句。
    in_context_since：原文最早那条还在它上下文里的时间。这之后记下的记忆，原话它眼前就有，
    再想起来是重复（09-27 Tilia发现：刚聊出来的几条每轮都被想起）——不参与联想。"""
    now = now or datetime.now(timezone.utc)
    shown = set(already_shown)
    people_hit = await match_people(pool, people_owner or user_id, text, exclude=shown, cfg=cfg)   # 人物卡归账号
    linked = {}
    for p in people_hit:      # 每张卡顺带几条跟这个人有关的记忆，越新越容易挑中（09-27）
        got = await linked_memories(pool, user_id, p, exclude=shown, before=in_context_since, now=now, rng=rng, cfg=cfg)
        shown |= {m.id for m in got}
        if got:
            linked[p.id] = got
    tier = LEVELS.get(level)
    if tier is None or not (probe.recall if probe is not None else worth_recalling(text)):
        return RecallResult(full=[], lines=[], people=people_hit, linked=linked)

    query = f"{text}\n{context}" if context else text
    vec = await embed_one(embedder, query)
    if vec is None:
        return RecallResult(full=[], lines=[], people=people_hit, linked=linked)
    topic_vec = await embed_one(embedder, probe.topic) if probe is not None and probe.topic else None

    rows = await pool.fetch(
        """SELECT id, created_at, 1 - (embedding <=> $2) AS sim,
                  CASE WHEN $4::vector IS NULL THEN NULL ELSE 1 - (embedding <=> $4) END AS tsim
           FROM memories
           WHERE user_id = $1 AND kind IN ('memory', 'about', 'diary') AND embedding IS NOT NULL
             AND ($3::timestamptz IS NULL OR created_at < $3)""",
        user_id, vec, in_context_since, topic_vec)
    if not rows:
        return RecallResult(full=[], lines=[], people=people_hit, linked=linked)

    ids = np.array([r["id"] for r in rows])
    sims = np.array([max(float(r["sim"]), float(r["tsim"]) if r["tsim"] is not None else -1.0) for r in rows])
    zs = zscores(sims)                       # z 分永远按全库算，窗口只是收窄候选
    small = len(rows) < cfg.min_for_z
    pool_idx = np.arange(len(rows))
    if probe is not None and probe.date_from is not None:     # 说到了哪几天：那几天里够像才只看那几天
        lo = datetime.combine(probe.date_from - timedelta(days=1), time.min, tzinfo=timezone.utc)
        hi = datetime.combine((probe.date_to or probe.date_from) + timedelta(days=2), time.min, tzinfo=timezone.utc)
        inside = np.array([i for i, r in enumerate(rows) if lo <= r["created_at"] < hi], dtype=int)
        if len(inside) and (small or float(zs[inside].max()) >= DATE_WINDOW_MIN_Z):
            pool_idx = inside
    top = pool_idx[np.argsort(-sims[pool_idx])][:20]
    kw_text = text
    if probe is not None:          # 关键词退化链：稀有词 → 话题 → 原句，滤完称呼和常见词还有词的那一级
        stop = await stopwords.for_user(pool, user_id, names)
        kw_text = next((t for t in (" ".join(probe.keywords), probe.topic, text) if words.tsquery(t, stop)), text)
    kw = set(await keyword_ids(pool, user_id, kw_text, cfg.search_candidates, kinds=("memory", "about", "diary"), names=names))
    mems = await store.fetch_many(pool, user_id, [int(ids[i]) for i in top])
    cands = [
        Candidate(memory=mems[int(ids[i])], sim=float(sims[i]), z=float(zs[i]), keyword=int(ids[i]) in kw)
        for i in top if int(ids[i]) in mems
    ]
    cands = await dedup(pool, user_id, cands, shown)
    if reranker is not None:
        full, lines = await rerank_pick(text, cands, tier, small, shown, reranker, cfg)
    else:
        full, lines = pick(cands, tier, small, shown, cfg.max_full, cfg.max_lines)
    # 09-28 起只读：浮上来不改库。10-01 起回想次数也不进分量公式了（见 decay.py），mark_used 只是记账。
    return RecallResult(
        full=[c.memory for c in full],
        lines=[RecallLine(memory_id=c.memory.id, snippet=snippet(c.memory.content, cfg.snippet_chars), kind=c.memory.kind)
               for c in lines],
        people=people_hit,
        linked=linked,
    )


USED_MIN_SHARED = 2     # 回复跟这条记忆共用这么多个有意义的词（两个字以上、不算称呼和常见词），才算真用上


async def mark_used(pool: asyncpg.Pool, user_id: UUID, memory_ids, reply: str, *, names=(),
                    now: datetime | None = None) -> list[int]:
    """这一轮浮上来的记忆里，回复真用上了的那几条记一笔「被想起」（刷新 last_recalled_at、recall_count +1；
    只给页面看，10-01 起不影响分量）。
    它自己调记忆工具翻出来的，搜索那边照旧算（那是它主动想的）。返回算上的那几条。"""
    ids = [int(i) for i in memory_ids or ()]
    if not ids or not (reply or "").strip():
        return []
    stop = await stopwords.for_user(pool, user_id, names)

    def meaningful(text: str) -> set[str]:
        return {t for t in words.tokens(text, stop) if len(t) >= 2}
    said = meaningful(reply)
    mems = await store.fetch_many(pool, user_id, ids)
    used = [mid for mid in ids if mid in mems
            and len(said & meaningful(mems[mid].content)) >= min(USED_MIN_SHARED, max(1, len(meaningful(mems[mid].content))))]
    if used:
        await store.touch(pool, user_id, used, now or datetime.now(timezone.utc))
    return used
