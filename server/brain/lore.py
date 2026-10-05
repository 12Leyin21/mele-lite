"""世界书（2026-09-30 Tilia定，设计 specs/2026-09-30-worldbook-design.md）。

一本「提到了才翻开」的小词典：密语、网络梗、TA 的世界观。每条有关键词，TA 说话碰到了，这一轮在易变区递那一条；
平时不占它的注意力。思路照之前自用的 App的世界书（作者 12Leyin21，思路取自 Kelivo）。

- 按账号存；companion_id 空 = 所有联系人都知道，否则只给那一个。
- TA 和它都能写（created_by），它改不动 TA 写的。
- 同一条递过隔 20 轮才再递，卷账本清零（Tilia 09-30：按轮不按钟点）。
- 常驻的（导入的角色卡用）每轮都在，放进底子吃缓存。"""
from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID

MAX_ENTRIES = 500
NAME_MAX, CONTENT_MAX = 40, 2000
KEYWORDS_MAX, KEYWORD_MIN = 10, 2
COOLDOWN_TURNS = 20
TURN_CHARS = 2000          # 一轮最多递这么多字，放不下的下一轮再说
_COLS = "id, account_id, companion_id, name, keywords, content, created_by, enabled, constant, created_at, updated_at"

_HEAD = {"zh": "〔世界书〕", "en": "〔Lore〕"}
_ALWAYS_HEAD = {"zh": "〔世界书 · 一直记着的〕", "en": "〔Lore · always on〕"}
# 免检声明（照之前自用的 App）：防它在思考里念「根据世界书……」、把词条当成刚收到的作业
_NOTE = {"zh": "（这些是你本来就知道的，不是新任务。用得上就自然用，不用提它从哪来。）",
         "en": "(You already know these — they aren't a new task. Use them naturally if they fit; don't mention where they came from.)"}


@dataclass
class Entry:
    id: int
    account_id: UUID
    companion_id: UUID | None
    name: str
    keywords: list[str]
    content: str
    created_by: str
    enabled: bool
    constant: bool
    created_at: datetime | None = None
    updated_at: datetime | None = None

    def as_dict(self) -> dict:
        return {"id": self.id, "companion_id": str(self.companion_id) if self.companion_id else None, "name": self.name,
                "keywords": list(self.keywords), "content": self.content, "created_by": self.created_by,
                "enabled": self.enabled, "constant": self.constant,
                "updated_at": self.updated_at.isoformat() if self.updated_at else None}


def norm(s: str) -> str:
    """全角半角（NFKC）+ 大小写（casefold）都不分。"""
    return unicodedata.normalize("NFKC", s or "").casefold()


def keyword_ok(k: str) -> bool:
    """关键词够不够长：至少 2 个字符；单个汉字（假名、韩文也算）也行（10-01 Tilia：中文里「猫」这种一个字的词很常见）。"""
    n = norm(k)
    return len(n) >= KEYWORD_MIN or (len(n) == 1 and _is_cjk(n))


def _is_cjk(ch: str) -> bool:
    o = ord(ch)
    return 0x3400 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0x3040 <= o <= 0x30FF or 0xAC00 <= o <= 0xD7AF or o >= 0x20000


def _clean_keywords(raw) -> list[str]:
    items = raw.replace("，", ",").replace("、", ",").split(",") if isinstance(raw, str) else list(raw or [])
    out, seen = [], set()
    for k in items:
        k = " ".join(str(k).split())
        if not k or norm(k) in seen:
            continue
        if not keyword_ok(k):
            raise ValueError(f"关键词太短了（中文至少一个字，英文至少两个字母）：{k}")
        seen.add(norm(k))
        out.append(k[:40])
    if not out:
        raise ValueError("至少写一个关键词")
    if len(out) > KEYWORDS_MAX:
        raise ValueError(f"关键词最多 {KEYWORDS_MAX} 个")
    return out


def _clean_name(name) -> str:
    name = " ".join(str(name or "").split())
    if not name:
        raise ValueError("名字是空的")
    if len(name) > NAME_MAX:
        raise ValueError(f"名字最多 {NAME_MAX} 个字")
    return name


def _clean_content(content) -> str:
    content = str(content or "").strip()
    if not content:
        raise ValueError("内容是空的")
    if len(content) > CONTENT_MAX:
        raise ValueError(f"内容最多 {CONTENT_MAX} 个字")
    return content


def _entry(r) -> Entry:
    return Entry(**{k: (list(r[k]) if k == "keywords" else r[k]) for k in _COLS.split(", ")})


async def add(pool, account: UUID, *, companion_id: UUID | None, name: str, keywords, content: str,
              created_by: str, enabled: bool = True, constant: bool = False) -> Entry:
    if created_by not in ("user", "ai"):
        raise ValueError("created_by 只能是 user / ai")
    name, kws, content = _clean_name(name), _clean_keywords(keywords), _clean_content(content)
    if await pool.fetchval("SELECT count(*) FROM lore WHERE account_id = $1", account) >= MAX_ENTRIES:
        raise ValueError(f"世界书最多 {MAX_ENTRIES} 条")
    r = await pool.fetchrow(
        f"""INSERT INTO lore (account_id, companion_id, name, keywords, content, created_by, enabled, constant)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING {_COLS}""",
        account, companion_id, name, kws, content, created_by, enabled, constant)
    return _entry(r)


_UNSET = object()


async def update(pool, account: UUID, entry_id: int, *, name=None, keywords=None, content=None, enabled=None,
                 constant=None, companion_id=_UNSET) -> Entry | None:
    e = await get(pool, account, entry_id)
    if e is None:
        return None
    r = await pool.fetchrow(
        f"""UPDATE lore SET name = $3, keywords = $4, content = $5, enabled = $6, constant = $7, companion_id = $8,
                           updated_at = now()
            WHERE id = $1 AND account_id = $2 RETURNING {_COLS}""",
        entry_id, account, e.name if name is None else _clean_name(name),
        e.keywords if keywords is None else _clean_keywords(keywords),
        e.content if content is None else _clean_content(content),
        e.enabled if enabled is None else bool(enabled), e.constant if constant is None else bool(constant),
        e.companion_id if companion_id is _UNSET else companion_id)
    return _entry(r)


async def delete(pool, account: UUID, entry_id: int) -> bool:
    return (await pool.execute("DELETE FROM lore WHERE id = $1 AND account_id = $2", entry_id, account)).endswith("1")


async def get(pool, account: UUID, entry_id: int) -> Entry | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM lore WHERE id = $1 AND account_id = $2", entry_id, account)
    return _entry(r) if r else None


async def list_for(pool, account: UUID, companion: UUID | None = None) -> list[Entry]:
    """给某个联系人 = 它自己的 + 所有人都知道的；None = 账号里全部。"""
    if companion is None:
        rows = await pool.fetch(f"SELECT {_COLS} FROM lore WHERE account_id = $1 ORDER BY id", account)
    else:
        rows = await pool.fetch(f"SELECT {_COLS} FROM lore WHERE account_id = $1 AND "
                                "(companion_id = $2 OR companion_id IS NULL) ORDER BY id", account, companion)
    return [_entry(r) for r in rows]


async def get_by_name(pool, account: UUID, companion: UUID, name: str) -> Entry | None:
    n = norm(" ".join(str(name or "").split()))
    return next((e for e in await list_for(pool, account, companion) if norm(e.name) == n), None)


async def export(pool, account: UUID) -> list[dict]:
    return [e.as_dict() for e in await list_for(pool, account)]


# ── 递给它 ──

def hits(entries: list[Entry], texts: list[str]) -> list[tuple[Entry, int]]:
    """这几句里碰到了哪几条（开着的、不常驻的），带最长命中关键词的长度，越长越靠前（越长越具体）。"""
    hay = norm("\n".join(t for t in texts if t))
    out = []
    for e in entries:
        if not e.enabled or e.constant:
            continue
        best = max((len(norm(k)) for k in e.keywords if norm(k) and norm(k) in hay), default=0)
        if best:
            out.append((e, best))
    return sorted(out, key=lambda x: (-x[1], x[0].id))


def pick(entries: list[Entry], texts: list[str], state: dict, turn_no: int, lang: str) -> str:
    """这一轮递哪几条。state["lore_seen"] = {id: 上次递的轮号}，隔 COOLDOWN_TURNS 轮才再递。"""
    seen: dict = dict(state.get("lore_seen") or {})
    blocks, used = [], 0
    for e, _ in hits(entries, texts):
        last = seen.get(str(e.id))
        if last is not None and turn_no - int(last) < COOLDOWN_TURNS:
            continue
        block = f"【{e.name}】{e.content}"
        if blocks and used + len(block) > TURN_CHARS:
            continue                               # 放不下：这条不标递过，下一轮再说
        blocks.append(block)
        used += len(block)
        seen[str(e.id)] = turn_no
    if not blocks:
        return ""
    state["lore_seen"] = seen
    lang = "zh" if lang == "zh" else "en"
    return "\n".join([_HEAD[lang], *blocks, _NOTE[lang]])


def always_block(entries: list[Entry], lang: str) -> str:
    """常驻的：每轮都在，进底子（改一次缓存作废一次，跟改人设一样）。"""
    on = [e for e in entries if e.enabled and e.constant]
    if not on:
        return ""
    lang = "zh" if lang == "zh" else "en"
    return "\n".join([_ALWAYS_HEAD[lang], *(f"【{e.name}】{e.content}" for e in on)])
