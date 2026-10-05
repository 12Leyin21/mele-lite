"""塔罗（10-03，设计 docs/specs/2026-10-03-tarot-design.md，计划 docs/plans/2026-10-03-tarot.md）。

- 洗牌不能是假的：服务器用自己的真随机 + TA 手搓的指尖轨迹定种子，洗一副 78 张、定好正逆位存起来（30 分钟有效）；
  手机只交「第几张」，服务器按存着的牌序取牌——交不了假牌。正位 0.65，没有加权（真牌也没有）。
- 谁来解：某个联系人（带人设和记忆），或解牌人（companion_id = NULL，中立：不带人设、不带记忆，也不告诉任何联系人）。
- 它自己问牌（工具）：纯服务器随机，mode = tool，它自己写解读。"""
from __future__ import annotations

import hashlib
import json
import random
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

from . import tarot_cards as TC
from .tarot_spreads import SPREADS

UPRIGHT = 0.65
DECK_TTL = timedelta(minutes=30)
MAX_QUESTION = 300
MAX_TEXT = 6000
MODES = ("hand", "auto", "tool")


class TarotError(ValueError):
    pass


def _j(raw):
    return json.loads(raw) if isinstance(raw, str) else raw


def _dump(v) -> str:
    return json.dumps(v, ensure_ascii=False)


def shuffle(seed: str) -> list[dict]:
    rng = random.Random(int(hashlib.sha256(seed.encode()).hexdigest(), 16))
    cards = list(TC.CARDS)
    rng.shuffle(cards)
    return [{"card": c, "reversed": rng.random() >= UPRIGHT} for c in cards]


def make_seed(trail: str = "") -> str:
    return hashlib.sha256(secrets.token_bytes(16) + (trail or "")[:4000].encode()).hexdigest()


@dataclass
class Reading:
    id: int
    companion_id: UUID | None
    route_from: UUID | None
    asker: str
    drawn_by: str
    question: str
    spread: str
    cards: list
    seed: str
    mode: str
    interpretation: str
    status: str
    tries: int
    told: bool
    followups: list
    created_at: datetime

    def public(self, lang: str) -> dict:
        sp = SPREADS[self.spread]

        def face(c: dict) -> dict:
            info = TC.card(c["card"], lang)
            return {"position": c["position"], "card": c["card"], "reversed": c["reversed"], "name": info["name"],
                    "keywords": info["reversed" if c["reversed"] else "upright"]["keywords"]}
        return {"id": self.id, "reader": str(self.companion_id) if self.companion_id else None,
                "asker": self.asker, "drawn_by": self.drawn_by, "question": self.question,
                "spread": self.spread, "spread_name": sp.name[lang], "mode": self.mode,
                "cards": [face(c) for c in self.cards], "interpretation": self.interpretation, "status": self.status,
                "followups": [{"question": f["question"], "card": face(f["card"]), "mode": f["mode"],
                               "interpretation": f.get("interpretation", ""), "status": f.get("status", "pending"),
                               "ts": f["ts"]} for f in self.followups],
                "created_at": self.created_at.isoformat()}


_COLS = ("id, companion_id, route_from, asker, drawn_by, question, spread, cards, seed, mode, interpretation, status, "
         "tries, told, followups, created_at")


def _row(r) -> Reading:
    d = dict(r)
    d["cards"], d["followups"] = _j(d["cards"]), _j(d["followups"])
    return Reading(**d)


def _question(q: str) -> str:
    q = (q or "").strip()
    if not q:
        raise TarotError("问题不能是空的")
    return q[:MAX_QUESTION]


async def new_deck(pool, account: UUID, trail: str = "", now: datetime | None = None) -> tuple[int, list[dict]]:
    seed = make_seed(trail)
    deck = shuffle(seed)
    if now is not None:
        await pool.execute("DELETE FROM tarot_decks WHERE account_id = $1 AND created_at < $2", account, now - DECK_TTL)
    did = await pool.fetchval("INSERT INTO tarot_decks (account_id, seed, deck, created_at) VALUES ($1, $2, $3::jsonb, "
                              "COALESCE($4, now())) RETURNING id", account, seed, _dump(deck), now)
    return did, deck


async def _take_deck(conn, account: UUID, deck_id: int, now: datetime) -> tuple[str, list[dict]]:
    r = await conn.fetchrow("DELETE FROM tarot_decks WHERE id = $1 AND account_id = $2 RETURNING seed, deck, created_at",
                            deck_id, account)
    if r is None or r["created_at"] < now - DECK_TTL:
        raise TarotError("这副牌找不到了或已经过期，重新洗一次")
    return r["seed"], _j(r["deck"])


def _picks(picks: list, n: int) -> list[int]:
    try:
        ps = [int(p) for p in picks]
    except (TypeError, ValueError) as e:
        raise TarotError("picks 要是数字") from e
    if len(ps) != n or len(set(ps)) != n or any(p < 0 or p >= 78 for p in ps):
        raise TarotError(f"要从这副牌里挑 {n} 张不重复的")
    return ps


async def save(pool, account: UUID, *, deck_id: int, spread: str, question: str, reader: UUID | None,
               route_from: UUID | None, picks: list, mode: str, now: datetime, lang: str = "zh") -> Reading:
    sp = SPREADS.get(spread)
    if sp is None or spread == "followup":
        raise TarotError("没有这个牌阵")
    if mode not in ("hand", "auto"):
        raise TarotError("mode 只能是 hand / auto")
    q = _question(question)
    ps = _picks(picks, sp.count)
    async with pool.acquire() as conn, conn.transaction():
        seed, deck = await _take_deck(conn, account, deck_id, now)
        cards = [{"position": pos, **deck[p]} for pos, p in zip(sp.positions[lang], ps)]
        r = await conn.fetchrow(
            f"""INSERT INTO tarot_readings (account_id, companion_id, route_from, question, spread, cards, seed, mode, created_at)
                VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9) RETURNING {_COLS}""",
            account, reader, route_from, q, spread, _dump(cards), seed, mode, now)
    return _row(r)


async def save_tool(pool, account: UUID, companion: UUID, *, question: str, spread: str, for_ta: bool,
                    now: datetime, lang: str = "zh") -> Reading:
    """它用工具抽：纯服务器随机，从牌顶发；解读它自己写（status 先 done，不排小轮）。"""
    sp = SPREADS.get(spread or "single")
    if sp is None or spread == "followup":
        raise TarotError("没有这个牌阵")
    q = _question(question)
    seed = make_seed()
    deck = shuffle(seed)
    cards = [{"position": pos, **deck[i]} for i, pos in enumerate(sp.positions[lang])]
    r = await pool.fetchrow(
        f"""INSERT INTO tarot_readings (account_id, companion_id, asker, drawn_by, question, spread, cards, seed, mode,
                                        status, created_at)
            VALUES ($1, $2, $3, 'contact', $4, $5, $6::jsonb, $7, 'tool', 'done', $8) RETURNING {_COLS}""",
        account, companion, "user" if for_ta else "contact", q, sp.key, _dump(cards), seed, now)
    return _row(r)


async def add_followup(pool, account: UUID, rid: int, *, deck_id: int, pick, question: str, mode: str,
                       now: datetime, lang: str = "zh") -> tuple[Reading, int]:
    if mode not in ("hand", "auto"):
        raise TarotError("mode 只能是 hand / auto")
    q = _question(question)
    [p] = _picks([pick], 1)
    async with pool.acquire() as conn, conn.transaction():
        r = await conn.fetchrow(f"SELECT {_COLS} FROM tarot_readings WHERE id = $1 AND account_id = $2 FOR UPDATE",
                                rid, account)
        if r is None:
            raise TarotError("没有这一局")
        reading = _row(r)
        if reading.status != "done" or not reading.interpretation.strip():
            raise TarotError("这一局还没解完，等解完再追问")
        seed, deck = await _take_deck(conn, account, deck_id, now)
        fu = {"question": q, "card": {"position": SPREADS["followup"].positions[lang][0], **deck[p]}, "seed": seed,
              "mode": mode, "interpretation": "", "status": "pending", "tries": 0, "ts": now.isoformat()}
        reading.followups.append(fu)
        await conn.execute("UPDATE tarot_readings SET followups = $2::jsonb WHERE id = $1", rid, _dump(reading.followups))
    return reading, len(reading.followups) - 1


async def write(pool, rid: int, text: str, *, followup: int | None = None) -> bool:
    """写解读。TA 抽、联系人解的主解读写好后 told = FALSE（下一轮递〔塔罗〕）；解牌人的、它自己抽的不递。"""
    text = (text or "").strip()[:MAX_TEXT]
    if not text:
        raise TarotError("解读不能是空的")
    async with pool.acquire() as conn, conn.transaction():
        r = await conn.fetchrow("SELECT companion_id, drawn_by, followups FROM tarot_readings WHERE id = $1 FOR UPDATE", rid)
        if r is None:
            return False
        if followup is None:
            told = r["companion_id"] is None or r["drawn_by"] == "contact"      # 它自己抽的局它本来就知道
            await conn.execute("UPDATE tarot_readings SET interpretation = $2, status = 'done', told = $3 WHERE id = $1",
                               rid, text, told)
            return True
        fus = _j(r["followups"])
        if not 0 <= followup < len(fus):
            raise TarotError("没有这个追问")
        fus[followup].update(interpretation=text, status="done")
        await conn.execute("UPDATE tarot_readings SET followups = $2::jsonb WHERE id = $1", rid, _dump(fus))
    return True


async def get(pool, account: UUID, rid: int) -> Reading | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM tarot_readings WHERE id = $1 AND account_id = $2", rid, account)
    return _row(r) if r else None


async def get_any(pool, rid: int) -> tuple[UUID, Reading] | None:
    r = await pool.fetchrow(f"SELECT account_id, {_COLS} FROM tarot_readings WHERE id = $1", rid)
    if r is None:
        return None
    d = dict(r)
    acc = d.pop("account_id")
    return acc, _row(d)


async def list_all(pool, account: UUID, *, companion: UUID | None = None, asker: str | None = None,
                   limit: int = 200) -> list[Reading]:
    where, args = ["account_id = $1"], [account]
    if companion:
        args.append(companion)
        where.append(f"companion_id = ${len(args)}")
    if asker in ("user", "contact"):
        args.append(asker)
        where.append(f"asker = ${len(args)}")
    args.append(limit)
    rows = await pool.fetch(f"SELECT {_COLS} FROM tarot_readings WHERE {' AND '.join(where)} "
                            f"ORDER BY created_at DESC, id DESC LIMIT ${len(args)}", *args)
    return [_row(r) for r in rows]


async def for_tool(pool, companion: UUID, limit: int = 5) -> list[Reading]:
    """它能翻到的：它自己问的 + 它解的（解牌人的局 companion_id 是 NULL，天然不在里面）。"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM tarot_readings WHERE companion_id = $1 "
                            "ORDER BY created_at DESC, id DESC LIMIT $2", companion, limit)
    return [_row(r) for r in rows]


async def retry(pool, account: UUID, rid: int) -> tuple[Reading, list[int]] | None:
    """解失败的（主解读或某个追问）退回 pending、次数清零。返回 (这一局, 退回的追问下标)；没有失败的返回 None。"""
    async with pool.acquire() as conn, conn.transaction():
        r = await conn.fetchrow(f"SELECT {_COLS} FROM tarot_readings WHERE id = $1 AND account_id = $2 FOR UPDATE",
                                rid, account)
        if r is None:
            return None
        reading = _row(r)
        idx = [i for i, f in enumerate(reading.followups) if f.get("status") == "failed"]
        if reading.status != "failed" and not idx:
            return None
        for i in idx:
            reading.followups[i].update(status="pending", tries=0)
        if reading.status == "failed":
            reading.status, reading.tries = "pending", 0
        await conn.execute("UPDATE tarot_readings SET status = $2, tries = $3, followups = $4::jsonb WHERE id = $1",
                           rid, reading.status, reading.tries, _dump(reading.followups))
    return reading, idx


async def delete(pool, account: UUID, rid: int) -> bool:
    return (await pool.execute("DELETE FROM tarot_readings WHERE id = $1 AND account_id = $2", rid, account)) != "DELETE 0"


async def export(pool, account: UUID) -> list[dict]:
    return [r.public("zh") for r in reversed(await list_all(pool, account, limit=100000))]


def cards_line(cards: list, lang: str) -> str:
    sep = "、" if lang == "zh" else ", "
    rev = "（逆）" if lang == "zh" else " (rev.)"
    return sep.join(f"{c['position']}·{TC.name(c['card'], lang)}{rev if c['reversed'] else ''}" for c in cards)


async def pending_note(pool, companion: UUID, lang: str) -> str:
    """〔塔罗〕：TA 抽、它解好的那一局，它下一次开口时递一次（解牌人的局不会到这儿）。一次只递一局。"""
    r = await pool.fetchrow(f"""UPDATE tarot_readings SET told = TRUE WHERE id = (
                                   SELECT id FROM tarot_readings WHERE companion_id = $1 AND NOT told
                                   ORDER BY created_at DESC LIMIT 1) RETURNING {_COLS}""", companion)
    if r is None:
        return ""
    x = _row(r)
    gist = " ".join(x.interpretation.split())
    gist = gist if len(gist) <= 120 else gist[:120] + "…"
    sp = SPREADS[x.spread].name[lang]
    if lang == "zh":
        return (f"〔塔罗〕TA 在塔罗房间里问了「{x.question}」（{sp}：{cards_line(x.cards, lang)}），"
                f"你给解了：{gist}　想聊就提。")
    return (f"〔Tarot〕In the Tarot room they asked \"{x.question}\" ({sp}: {cards_line(x.cards, lang)}), "
            f"and you read it: {gist}  Bring it up if you like.")

