"""数据类。数据库一行 → Memory；对外返回的结果也都在这里定义。"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from uuid import UUID

KINDS = ("memory", "core", "person", "about", "diary")
# 「关于 TA」：TA 的日常小事；「日记」：Ta 的日记（10-01，日记房间里看）。TA 在记忆页看不到这两类（不进列表、不进网状图），
# 但导出和清空照样带上
HIDDEN_KINDS = ("about", "diary")

# 查 Memory 时统一用这一串列，row_to_memory 按名字取
MEMORY_COLUMNS = (
    "id, user_id, kind, content, name, aliases, relation, impression, created_by, updated_by, "
    "importance, valence, arousal, "
    "tags, resolved, created_at, updated_at, last_recalled_at, recall_count, rewritten_at, "
    "(embedding IS NOT NULL) AS has_embedding"
)


@dataclass
class Memory:
    id: int
    user_id: UUID
    kind: str
    content: str
    importance: int
    valence: float
    arousal: float
    tags: list[str]
    resolved: bool
    created_at: datetime
    updated_at: datetime
    last_recalled_at: datetime | None
    recall_count: int
    name: str | None = None
    aliases: list[str] = field(default_factory=list)
    relation: str | None = None
    impression: str = ""          # 人物卡：它自己的印象
    created_by: str = "user"      # 谁写的：user / ai
    updated_by: str = "user"
    has_embedding: bool = False
    rewritten_at: datetime | None = None   # 内容最后一次改写/合并；淡去从这里重新算（10-01）

    def to_dict(self) -> dict:
        d = asdict(self)
        d["user_id"] = str(self.user_id)
        for key in ("created_at", "updated_at", "last_recalled_at", "rewritten_at"):
            d[key] = d[key].isoformat() if d[key] else None
        return d


def row_to_memory(r) -> Memory:
    return Memory(
        id=r["id"], user_id=r["user_id"], kind=r["kind"], content=r["content"],
        importance=r["importance"], valence=float(r["valence"]), arousal=float(r["arousal"]),
        tags=list(r["tags"] or []), resolved=r["resolved"],
        created_at=r["created_at"], updated_at=r["updated_at"],
        last_recalled_at=r["last_recalled_at"], recall_count=r["recall_count"],
        name=r["name"], aliases=list(r["aliases"] or []), relation=r["relation"],
        impression=r["impression"] or "", created_by=r["created_by"], updated_by=r["updated_by"],
        has_embedding=bool(r["has_embedding"]), rewritten_at=r.get("rewritten_at"),
    )


@dataclass
class RememberResult:
    memory: Memory
    merged: bool          # True = 合并进了一条旧记忆


@dataclass
class SearchHit:
    memory: Memory
    score: float
    sim: float | None     # 向量相似度；这条只靠关键词找到时为 None
    keyword: bool         # 关键词也命中了


@dataclass
class RecallLine:
    memory_id: int
    snippet: str
    kind: str = "memory"      # memory / about——拼会变区时分开放


@dataclass
class RecallResult:
    full: list[Memory]    # 很相关：整条放进上下文
    lines: list[RecallLine]  # 有点相关：一行摘要
    people: list[Memory]  # 这句提到的人物卡
    linked: dict[int, list[Memory]] = field(default_factory=dict)   # 人物卡 id → 跟这个人有关、这次一起递上去的记忆

    def surfaced_ids(self) -> set[int]:
        return {m.id for m in self.full} | {l.memory_id for l in self.lines} | {p.id for p in self.people}


@dataclass
class Probe:
    """召回哨兵听懂这句之后给的（brain/probe.py）：要不要翻、话题说全的一句、稀有关键词、说到的日期。"""
    recall: bool = True
    topic: str = ""
    keywords: tuple[str, ...] = ()
    date_from: date | None = None
    date_to: date | None = None
    usage: object = None          # 这次哨兵花的 token（大脑记账用）
