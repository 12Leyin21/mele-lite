"""每日私选的网络那半（09-30，音乐第 6 步）。照之前自用的 App 的中继 app.py 的今日私选（12Leyin21 写的）：

每天 TA 起床后半小时（或 TA 自己定的点），巡逻钟 kind='picks' 响 → 先建今天的候选池（程序从曲库里找的真歌）→
叫醒 Lumi（理由 picks，一定开口），〔醒来〕里给它池子和前几天 TA 的反馈 → 它用 music(action=picks) 交卷，
每首一张歌卡跟着它那条消息进聊天流（Tilia 09-25 在之前自用的 App要的：推荐的歌发到聊天里，附上为什么选这首）。

选过听歌平台（music_links 有那一行）才开这个钟。出错不抛，池子空着就今天不推。"""
from __future__ import annotations

import json
import logging
import random
from datetime import date, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

import memory as M
from brain import accounts, archive
from brain.auth import TrialOver, charge_trial
from brain.context import user_tag
from brain.scope import Scope
from brain.settings import Settings
from llm.catalog import cost
from llm.router import call
from llm.types import ChatRequest, Msg

from . import picks as P
from . import store as S
from .find import DEFAULT_STOREFRONT, alt_names

log = logging.getLogger(__name__)
AFTER_WAKE = timedelta(minutes=30)
FAMILIAR_SEEDS, FAMILIAR_SONGS = 4, 10
NEW_ARTISTS, NEW_SONGS = 10, 6
TASTE_QUERY = "喜欢听的歌 歌手 音乐 乐队"


# ── 钟 ──

async def _main(pool, account: UUID):
    comps = await accounts.list_companions(pool, account)
    if not comps:
        return None, Settings()
    return comps[0], Settings.from_dict(await archive.get_settings(pool, comps[0]))


def next_time(now: datetime, s: Settings, picks_at: str = "") -> datetime:
    """下一次推歌：TA 定了点就用那个点；没定 = 起床时间 + 半小时。按 TA 的时区，今天过了就明天。"""
    tz = ZoneInfo(s.tz)
    if picks_at:
        h, m = (int(x) for x in picks_at.split(":"))
        at = time(h, m)
    else:
        h, m = (int(x) for x in s.sleep_to.split(":"))
        at = (datetime.combine(date(2000, 1, 1), time(h, m)) + AFTER_WAKE).time()
    local = now.astimezone(tz)
    t = datetime.combine(local.date(), at, tzinfo=tz)
    return t if t > local else t + timedelta(days=1)


async def ensure_clock(pool, account: UUID, now: datetime) -> None:
    """选了听歌平台就有一个推歌的钟（没有就挂上，时间按现在的设置重算）；没选 = 删掉。"""
    from patrol import store as clock_store
    comp, s = await _main(pool, account)
    await pool.execute("DELETE FROM clocks WHERE account_id = $1 AND kind = 'picks'", account)
    row = await pool.fetchrow("SELECT picks_n, picks_at FROM music_links WHERE account_id = $1", account)
    if comp is None or row is None or row["picks_n"] <= 0:
        return
    at = next_time(now, s, row["picks_at"])
    await clock_store.add_clock(pool, account, comp, kind="picks", shape="once", spec={"at": at.isoformat()},
                                note="", next_at=at)


# ── 建池子 ──

async def _ask_names(deps, scope: Scope, prompt: str, day: date) -> list[str]:
    """请它那把钥匙的便宜模型报一串歌手名（只要名字，歌由曲库验）。额度用完 / 出错 = []。"""
    from brain.turn import get_adapter, resolve_route
    try:
        route = await resolve_route(deps.keys, scope)
    except TrialOver:
        return []
    model = route.ledger_model or route.chat_model
    try:
        reply = await call(get_adapter(deps, route), ChatRequest(
            model=model, system=[], messages=[Msg("user", prompt)], max_tokens=300, thinking=False,
            user_tag=user_tag(scope.account)))
    except Exception as e:                                      # noqa: BLE001 —— 甜点
        log.warning("picks: ask names failed: %r", e)
        return []
    spent = cost(reply.usage, model)
    await archive.add_usage(deps.pool, scope.account, day, model, reply.usage, spent)
    if route.trial and spent:
        await charge_trial(deps.pool, scope.account, round(spent * 1_000_000))
    return P.parse_artist_list(reply.text)


async def _songs_of(am, artist: str, sf: str, origin: str, limit: int) -> list[dict]:
    found = await am.search_artists(artist, sf, 1)
    if not found:
        return []
    got = await am.artist_top_songs(found[0].id, sf, limit)
    return [{**x.as_dict(), "origin": origin} for x in got if P.by_artist(x.as_dict(), found[0].name)]


async def build(deps, account: UUID, day: date, rng: random.Random | None = None) -> list[dict]:
    """建今天的候选池并存下。建过了就直接给存着的。"""
    pool, am = deps.pool, getattr(deps, "music", None)
    have = await pool.fetchval("SELECT pool FROM music_pools WHERE account_id = $1 AND day = $2", account, day)
    if have is not None:
        return have if isinstance(have, list) else json.loads(have)
    if am is None:
        return []
    comp, s = await _main(pool, account)
    if comp is None:
        return []
    conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND NOT incognito "
                               "ORDER BY last_at DESC LIMIT 1", comp)
    scope = Scope(account, comp, conv or comp)
    box = getattr(deps.keys, "box", None)
    link = await S.get_link(pool, box, account) if box else None
    sf = (link.storefront if link else "") or await S.storefront_of(pool, account) or DEFAULT_STOREFRONT
    token = link.user_token if link else None
    top = await am.heavy_rotation_artists(token) if token else []
    recent = await am.recent_tracks(token, 30) if token else []
    shelf = await S.shelf(pool, account, 50)
    scores = await S.artist_scores(pool, account)
    played = [(x.artist, 1) for x in recent] + [(x["artist"], 1) for x in shelf]
    seeds = P.seed_artists(played, top, scores, n=8, rng=rng)
    if not seeds:                                               # 没连、也没投过票：从它记得的 TA 猜
        hits = await M.search(pool, deps.embedder, comp, TASTE_QUERY, limit=8, touch=False)
        if hits:
            seeds = (await _ask_names(deps, scope, P.taste_prompt([h.memory.content for h in hits]), day))[:6]
    if not seeds:
        log.info("picks %s %s: 没有种子，今天不推", account, day)
        return []
    known = ({x.lower() for art, _ in played for x in P.split_artists(art)} | {a.lower() for a in top}
             | {x.lower() for x in seeds})
    blocked = [k for k, v in scores.items() if v <= P.BLOCK_SCORE]
    new: list[str] = []
    for seed in seeds[:3]:                                      # 先用 Apple Music 的「相似歌手」
        found = await am.search_artists(seed, sf, 1)
        for a in (await am.similar_artists(found[0].id, sf)) if found else []:
            if a.name.lower() not in known and a.name.lower() not in blocked and a.name not in new:
                new.append(a.name)
    if len(new) < 5:                                            # 不够再请模型报（只报名字）
        for name in await _ask_names(deps, scope, P.similar_prompt(seeds, blocked), day):
            if name.lower() not in known and name not in new:
                new.append(name)
    candidates: list[dict] = []
    for a in seeds[:FAMILIAR_SEEDS]:
        candidates += await _songs_of(am, a, sf, "familiar", FAMILIAR_SONGS)
    for a in new[:NEW_ARTISTS]:
        candidates += await _songs_of(am, a, sf, "new", NEW_SONGS)
    heard = await S.heard_keys(pool, account) | {P.song_key(x.name, x.artist) for x in recent} \
        | {P.song_key(x["name"], x["artist"]) for x in shelf}
    recent_ids = {r["song_id"] for r in await pool.fetch(
        "SELECT song_id FROM music_picks WHERE account_id = $1 AND day > $2", account, day - timedelta(days=P.KEEP_DAYS))}
    chosen = P.build_pool(candidates, heard, recent_ids, scores, rng=rng)
    alt = await alt_names(am, [c["id"] for c in chosen], sf, s.lang)     # 只有英文的区：七里香别变成 Qi-Li-Xiang
    for c in chosen:
        if c["id"] in alt:
            c["name"], c["artist"] = alt[c["id"]].name, alt[c["id"]].artist
    if chosen:
        await pool.execute(
            """INSERT INTO music_pools (account_id, day, pool, seeds) VALUES ($1, $2, $3::jsonb, $4::jsonb)
               ON CONFLICT (account_id, day) DO NOTHING""",
            account, day, json.dumps(chosen, ensure_ascii=False),
            json.dumps({"seeds": seeds, "new": new}, ensure_ascii=False))
    log.info("picks %s %s: 池子 %d 首（种子 %s，新歌手 %s）", account, day, len(chosen), seeds, new)
    return chosen


async def pool_of(pool, account: UUID, day: date) -> list[dict]:
    got = await pool.fetchval("SELECT pool FROM music_pools WHERE account_id = $1 AND day = $2", account, day)
    if got is None:
        return []
    return got if isinstance(got, list) else json.loads(got)


# ── 〔醒来〕里那段 ──

_VOTE = {"zh": {"up": "多来点", "meh": "无感", "down": "少来点"}, "en": {"up": "more like this", "meh": "meh", "down": "less like this"}}


async def wake_note(pool, account: UUID, day: date, chosen: list[dict], lang: str) -> str:
    n = await pool.fetchval("SELECT picks_n FROM music_links WHERE account_id = $1", account) or P.PICKS_DEFAULT
    fb = await pool.fetch("""SELECT name, artist, vote, stars, reason FROM music_picks
                             WHERE account_id = $1 AND vote <> '' AND day < $2 ORDER BY day DESC, pos LIMIT 9""", account, day)
    zh = lang == "zh"
    fam = {"familiar": "熟" if zh else "familiar", "new": "新" if zh else "new"}
    lines = [f"#{c['id']} {c['name']} - {c['artist']}（{fam.get(c.get('origin'), '新')}）" if zh
             else f"#{c['id']} {c['name']} - {c['artist']} ({fam.get(c.get('origin'), 'new')})" for c in chosen]
    v = _VOTE["zh" if zh else "en"]
    feedback = [f"- {r['name']} - {r['artist']}：{v.get(r['vote'], r['vote'])}" + (f" ★{r['stars']}" if r["stars"] else "")
                + (f"「{r['reason']}」" if r["reason"] else "") for r in fb]
    if zh:
        out = ["今天的私选候选备好了（程序从曲库里找的真歌，只能从这里挑；熟 = TA 常听的歌手，新 = 风格相近、TA 可能没听过的）："] + lines
        if feedback:
            out += ["TA 前几天对你挑的歌怎么说："] + feedback
        out.append(f'挑 {n} 首 TA 今天可能喜欢的，用 music(action="picks", picks=[{{"id": "编号", "why": "为什么是这首，一句"}}]) 交；'
                   "交完跟 TA 说一两句（歌卡会跟着这条消息发过去）。")
    else:
        out = ["Today's pick candidates are ready (real songs the app found in the catalog; pick only from these; "
               "familiar = artists they play a lot, new = similar artists they may not know):"] + lines
        if feedback:
            out += ["What they said about your recent picks:"] + feedback
        out.append(f'Pick {n} they might like today with music(action="picks", picks=[{{"id": "…", "why": "one line: why this one"}}]); '
                   "then say a line or two to them (the song cards go out with that message).")
    return "\n".join(out)
