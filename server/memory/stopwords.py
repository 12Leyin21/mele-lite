"""称呼停用词（2026-09-28，召回改造第 1 步；思路见 docs/research/2026-09-recall-ideas.md 第 2 条）。

「一个常用称呼就能喊坏整张榜」：它的名字、用户给它起的昵称、用户自己的名字，几乎每条记忆里都有，
拿去关键词榜一搜就命中半个库，关键词那一路等于瞎了。停用词三层：
1. 虚词表（words.STOPWORDS，所有人一样）；
2. 称呼：调用方给名字（大脑传人设里的名字和用户的名字），整个名字和切出来的词都停；
3. 这个用户记忆里太常见的词，自动停——**按用户算**，每个人的称呼、口头禅都不一样。
   「太常见」：出现在 ratio 以上的记忆里，ratio 随库大小从 20%（小库）滑到 2%（上千条，之前自用的 App真库上试出来的线），
   而且至少 MIN_DOCS 条——记忆太少时不自动停，免得把真正的话题停掉。
用 Postgres 的 ts_stat 直接数（关键词那一栏本来就是分好词的），结果按「条数 + 最新一条 + 最后改动」缓存，库变了才重数。"""
from __future__ import annotations

from uuid import UUID

import asyncpg

from . import words

MIN_DOCS = 5          # 至少这么多条记忆里都有，才自动当停用词
RATIO_SMALL = 0.20    # 小库：出现在两成以上的记忆里
RATIO_LARGE = 0.02    # 大库（上千条）：2%——之前自用的 App 09-28 真库 1045 桶试了 3% / 2% / 1.5% / 1%，2% 人名地名都还认
DOCS_FOR_LARGE = 20   # 中间按「至少 20 条」过渡：ratio = clamp(20 / 总数, 2%, 20%)

_cache: dict[UUID, tuple[tuple, frozenset[str]]] = {}


def name_tokens(names) -> set[str]:
    """称呼：整个名字（小写）加上切出来的词。空的跳过。"""
    out: set[str] = set()
    for n in names or ():
        n = (n or "").strip().lower()
        if not n:
            continue
        out.add(n)
        out.update(words.tokens(n))
    return out


def ratio_for(total: int) -> float:
    return min(RATIO_SMALL, max(RATIO_LARGE, DOCS_FOR_LARGE / max(total, 1)))


async def frequent(pool: asyncpg.Pool, user_id: UUID) -> frozenset[str]:
    """这个用户记忆里太常见的词。库没变就用上次数的。"""
    sig_row = await pool.fetchrow(
        "SELECT count(*) AS n, max(id) AS top, max(updated_at) AS upd FROM memories WHERE user_id = $1", user_id)
    sig = (sig_row["n"], sig_row["top"], sig_row["upd"])
    hit = _cache.get(user_id)
    if hit and hit[0] == sig:
        return hit[1]
    total = sig_row["n"]
    out: frozenset[str] = frozenset()
    if total >= MIN_DOCS:
        need = max(MIN_DOCS, ratio_for(total) * total)
        # ts_stat 只收一段 SQL 文本；user_id 先转成 UUID 再格式化进去，不会有注入
        inner = f"SELECT search_tsv FROM memories WHERE user_id = '{UUID(str(user_id))}'"
        rows = await pool.fetch("SELECT word, ndoc FROM ts_stat($1) WHERE ndoc >= $2", inner, need)
        out = frozenset(r["word"] for r in rows)
    _cache[user_id] = (sig, out)
    return out


async def for_user(pool: asyncpg.Pool, user_id: UUID, names=()) -> frozenset[str]:
    """这个用户这一次搜索用的额外停用词：称呼 + 他库里太常见的词。"""
    return frozenset(name_tokens(names)) | await frequent(pool, user_id)
