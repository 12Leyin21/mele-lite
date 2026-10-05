"""给 app 的「它记得的」网状页面：每条记忆一个点，点的大小看当前分量；
意思相近的连一条线（每个点最多连 k 个最像的），提到某个人的记忆连到那张人物卡。"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from uuid import UUID

import asyncpg
import numpy as np

from .config import DEFAULT, MemoryConfig
from .decay import weight
from .models import MEMORY_COLUMNS, row_to_memory
from .people import keywords, mentions

LABEL_CHARS = 24


@dataclass
class GraphNode:
    id: int
    label: str
    kind: str
    weight: float


@dataclass
class GraphEdge:
    source: int
    target: int
    kind: str        # "similar" / "person"
    strength: float


@dataclass
class Graph:
    nodes: list[GraphNode]
    edges: list[GraphEdge]

    def to_dict(self) -> dict:
        return {"nodes": [asdict(n) for n in self.nodes], "edges": [asdict(e) for e in self.edges]}


async def graph(pool: asyncpg.Pool, user_id: UUID, *, k: int = 3, min_sim: float = 0.6,
                now: datetime | None = None, cfg: MemoryConfig = DEFAULT) -> Graph:
    now = now or datetime.now(timezone.utc)
    rows = await pool.fetch(
        f"SELECT {MEMORY_COLUMNS}, embedding FROM memories WHERE user_id = $1 AND kind NOT IN ('about', 'diary') ORDER BY id", user_id)
    mems = [row_to_memory(r) for r in rows]
    nodes = [
        GraphNode(id=m.id, label=(m.name or m.content)[:LABEL_CHARS], kind=m.kind,
                  weight=round(weight(m, now, cfg), 4))
        for m in mems
    ]
    edges: list[GraphEdge] = []
    seen: set[frozenset] = set()

    with_vec = [(m.id, np.asarray(r["embedding"], dtype=np.float32))
                for m, r in zip(mems, rows) if r["embedding"] is not None and m.kind != "person"]
    if len(with_vec) > 1:
        ids = [i for i, _ in with_vec]
        mat = np.stack([v for _, v in with_vec])
        sim = mat @ mat.T
        np.fill_diagonal(sim, -1.0)
        for a in range(len(ids)):
            for b in np.argsort(-sim[a])[:k]:
                s = float(sim[a, b])
                pair = frozenset((ids[a], ids[int(b)]))
                if s >= min_sim and pair not in seen:
                    seen.add(pair)
                    edges.append(GraphEdge(source=ids[a], target=ids[int(b)], kind="similar",
                                           strength=round(s, 4)))

    for p in (m for m in mems if m.kind == "person"):
        names = keywords(p)
        for m in mems:
            if m.kind == "person":
                continue
            if any(mentions(n, m.content) >= 0 for n in names):
                edges.append(GraphEdge(source=p.id, target=m.id, kind="person", strength=1.0))
    return Graph(nodes=nodes, edges=edges)
