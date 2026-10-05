"""音乐的存取（09-30，音乐第 3 步）：连接、歌单、私选、投票、听过的。全部按账号隔开。"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from uuid import UUID

from .apple import Song
from .picks import REASON_MAX, split_artists, vote_weight

PLATFORMS = ("apple", "netease", "qq", "spotify", "other")
_SONG = "song_id, name, artist, artwork, preview, url"


@dataclass(frozen=True)
class Link:
    platform: str
    user_token: str | None
    storefront: str
    picks_n: int = 3
    picks_at: str = ""


async def link(pool, box, account: UUID, *, platform: str, user_token: str | None = None, storefront: str = "") -> None:
    if platform not in PLATFORMS:
        raise ValueError(f"不认识这个平台：{platform}")
    blob = box.lock(user_token) if user_token and platform == "apple" else None
    await pool.execute(
        """INSERT INTO music_links (account_id, platform, user_token, storefront, linked_at) VALUES ($1, $2, $3, $4, now())
           ON CONFLICT (account_id) DO UPDATE SET platform = $2, user_token = $3, storefront = $4, linked_at = now()""",
        account, platform, blob, storefront or "")


async def unlink(pool, account: UUID) -> None:
    await pool.execute("DELETE FROM music_links WHERE account_id = $1", account)


async def storefront_of(pool, account: UUID) -> str:
    """TA 的 Apple Music 在哪个区（不用解凭证）；没连 = 空。"""
    return await pool.fetchval("SELECT storefront FROM music_links WHERE account_id = $1", account) or ""


async def get_link(pool, box, account: UUID) -> Link | None:
    r = await pool.fetchrow("SELECT platform, user_token, storefront, picks_n, picks_at FROM music_links "
                            "WHERE account_id = $1", account)
    if r is None:
        return None
    return Link(r["platform"], box.unlock(bytes(r["user_token"])) if r["user_token"] else None, r["storefront"],
                r["picks_n"], r["picks_at"])


async def shelve(pool, account: UUID, s: Song, *, source: str, why: str) -> None:
    await pool.execute(
        f"""INSERT INTO music_shelf (account_id, {_SONG}, source, why) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (account_id, song_id) DO NOTHING""",
        account, s.id, s.name, s.artist, s.artwork, s.preview, s.url, source, (why or "").strip())


async def shelf(pool, account: UUID, limit: int = 200) -> list[dict]:
    rows = await pool.fetch(f"SELECT id, {_SONG}, source, why, created_at FROM music_shelf WHERE account_id = $1 "
                            "ORDER BY created_at DESC, id DESC LIMIT $2", account, limit)
    return [{**dict(r), "created_at": r["created_at"].isoformat()} for r in rows]


async def save_picks(pool, account: UUID, day: date, picks: list[tuple[Song, str]]) -> None:
    async with pool.acquire() as con, con.transaction():
        await con.execute("DELETE FROM music_picks WHERE account_id = $1 AND day = $2", account, day)
        for pos, (s, why) in enumerate(picks):
            await con.execute(
                f"""INSERT INTO music_picks (account_id, day, pos, {_SONG}, why)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)""",
                account, day, pos, s.id, s.name, s.artist, s.artwork, s.preview, s.url, why)


async def picks_on(pool, account: UUID, day: date) -> list[dict]:
    rows = await pool.fetch(f"SELECT pos, {_SONG}, why, vote, stars, reason FROM music_picks "
                            "WHERE account_id = $1 AND day = $2 ORDER BY pos", account, day)
    return [dict(r) for r in rows]


async def vote(pool, account: UUID, day: date, pos: int, v: str, *, stars: int | None = None,
               reason: str | None = None) -> dict | None:
    """TA 点「多来点 / 无感 / 少来点」（up / meh / down，空 = 撤销）。歌手净分按「这次 - 上次」算，反复点不会刷分。
    换了方向星星归零重打；撤销就星星和理由一起清掉（照之前自用的 App apply_vote）。"""
    if v not in ("up", "meh", "down", ""):
        return None
    async with pool.acquire() as con, con.transaction():
        r = await con.fetchrow("SELECT artist, vote, stars FROM music_picks WHERE account_id = $1 AND day = $2 AND pos = $3 "
                               "FOR UPDATE", account, day, pos)
        if r is None:
            return None
        new_stars = (r["stars"] if v == r["vote"] else 0) if stars is None else max(0, min(5, int(stars)))
        if v not in ("up", "down"):
            new_stars = 0
        delta = vote_weight(v, new_stars) - vote_weight(r["vote"], r["stars"])
        new_reason = "" if v == "" else None if reason is None else " ".join(str(reason).split())[:REASON_MAX]
        await con.execute("UPDATE music_picks SET vote = $4, stars = $5, reason = COALESCE($6, reason) "
                          "WHERE account_id = $1 AND day = $2 AND pos = $3", account, day, pos, v, new_stars, new_reason)
        if delta:
            for a in split_artists(r["artist"]):
                await con.execute("""INSERT INTO music_votes (account_id, artist, score) VALUES ($1, $2, $3)
                                     ON CONFLICT (account_id, artist) DO UPDATE SET score = music_votes.score + $3""",
                                  account, a.lower(), delta)
            await con.execute("DELETE FROM music_votes WHERE account_id = $1 AND score = 0", account)
    return next(p for p in await picks_on(pool, account, day) if p["pos"] == pos)


async def artist_scores(pool, account: UUID) -> dict[str, int]:
    return {r["artist"]: r["score"] for r in await pool.fetch(
        "SELECT artist, score FROM music_votes WHERE account_id = $1", account)}


async def note_heard(pool, account: UUID, keys: list[str]) -> None:
    for k in keys:
        await pool.execute("""INSERT INTO music_heard (account_id, song_key) VALUES ($1, $2)
                              ON CONFLICT (account_id, song_key) DO UPDATE SET last_at = now()""", account, k)


async def heard_keys(pool, account: UUID) -> set[str]:
    return {r["song_key"] for r in await pool.fetch("SELECT song_key FROM music_heard WHERE account_id = $1", account)}


async def export(pool, account: UUID) -> dict:
    """导出：平台和区、歌单、私选、歌手分（用户凭证不导）。"""
    ln = await pool.fetchrow("SELECT platform, storefront FROM music_links WHERE account_id = $1", account)
    picks = await pool.fetch(f"SELECT day, pos, {_SONG}, why, vote, stars, reason FROM music_picks "
                             "WHERE account_id = $1 ORDER BY day, pos", account)
    return {"link": dict(ln) if ln else None, "shelf": await shelf(pool, account, limit=10_000),
            "picks": [{**dict(p), "day": p["day"].isoformat()} for p in picks],
            "artist_scores": await artist_scores(pool, account)}
