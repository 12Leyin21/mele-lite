"""每日私选的纯逻辑（09-30）。移植自之前自用的 App 的中继 daily_picks.py（12Leyin21 写的），Spotify 换成 Apple Music。

核心规矩：**程序先找真歌，模型只从候选里挑**。池子里每一首都是 TA 那个区曲库里真有的、TA 没放过的；
Lumi 挑 N 首、每首写一句为什么；池子外的编号一律打回。
- 种子歌手：TA 常听的（Apple Music「最近常听」）、最近放过的、它分享过的，加上 TA 点过「多来点」的
- 新歌手：先用 Apple Music 的「相似歌手」；不够再请模型按种子报风格相近的歌手名，**只报名字**，每个名字去曲库搜得到才算
- TA 点过「少来点」的歌手净分 ≤ -3 就不再进池子（一首歌最多 -2，拉黑不了歌手）

纯逻辑，不碰网络。网络那半在 daily.py。"""
from __future__ import annotations

import json
import random
import re

POOL_LIMIT = 30          # 一天的候选池
PER_ARTIST = 3           # 一个歌手最多占几首
PICKS_DEFAULT, PICKS_MIN, PICKS_MAX = 3, 1, 5     # 每天几首（Tilia：之前自用的 App 5 首有点多，3 首就够；Mele 可调）
WHY_MAX = 120
KEEP_DAYS = 30
REASON_MAX = 200
BLOCK_SCORE = -3

_COVERISH = re.compile(r"(伴奏|钢琴版|鋼琴版|翻唱|cover|karaoke|instrumental|piano ver|lofi|sped up|slowed|8d audio)", re.I)
_VARIANT = re.compile(r"\s*[\(\[（【-].*?(live|remaster|version|edit|mix|acoustic|demo|现场|版).*$", re.I)


def song_key(name: str, artist: str) -> str:
    raw = f"{name}|{artist}".lower()
    return re.sub(r"[^0-9a-z一-鿿|]+", "", raw)[:160]


def split_artists(artists: str) -> list[str]:
    return [a.strip() for a in re.split(r"\s*(?:[、,，/]|&| feat\. | ft\. )\s*", artists or "", flags=re.I) if a.strip()]


def vote_weight(vote: str, stars: int = 0) -> int:
    """歌手净分这一票值多少：喜欢为正、不喜欢为负、无感 0。没打星或 1~4 星 = 1 分，5 星 = 2 分。
    **一首歌永远拉黑不了一个歌手**（之前自用的 App 09-27 Tilia：可能只是特别不喜欢某一首）。"""
    sign = {"up": 1, "down": -1}.get(vote, 0)
    return sign * (2 if stars >= 5 else 1)


def seed_artists(played: list[tuple[str, int]], top_artists: list[str], scores: dict[str, int],
                 n: int = 8, rng: random.Random | None = None) -> list[str]:
    """挑今天的种子歌手。played：[(歌手署名, 放了几次)]；top_artists：最常听的，越前越重；scores：歌手小写 → 净分。
    按权重抽，不是每天都拿前八——不然天天同一批种子、同一批候选。"""
    rng = rng or random.Random()
    weight: dict[str, float] = {}
    display: dict[str, str] = {}

    def add(name: str, w: float):
        key = name.lower()
        display.setdefault(key, name)
        weight[key] = weight.get(key, 0) + w

    for artists, plays in played or []:
        for a in split_artists(artists):
            add(a, 1 + min(max(1, plays), 10) * 0.5)
    for i, name in enumerate(top_artists or []):
        add(name, max(1.0, 4 - i * 0.2))
    for key, s in (scores or {}).items():                   # 点过「多来点」的：没放过也当种子
        if s > 0:
            add(key, 2 * s)
    pool = [k for k in weight if (scores or {}).get(k, 0) > BLOCK_SCORE]
    picked = []
    while pool and len(picked) < n:
        total = sum(weight[k] for k in pool)
        r = rng.uniform(0, total)
        for k in pool:
            r -= weight[k]
            if r <= 0:
                picked.append(display[k])
                pool.remove(k)
                break
    return picked


def similar_prompt(seeds: list[str], avoid: list[str], n: int = 10) -> str:
    return (
        "下面是一个人最近常听的歌手：\n" + "、".join(seeds) + "\n\n"
        f"请推荐 {n} 位风格相近、但**不在上面名单里**的歌手或乐队，最好有一半是 TA 大概没听过的小众一点的。"
        + (("\n不要推荐这些：" + "、".join(avoid)) if avoid else "")
        + "\n只输出一个 JSON 数组，元素是歌手在 Apple Music 上的名字（用原文，不要翻译），不要解释："
        '\n["歌手1", "歌手2"]'
    )


def taste_prompt(notes: list[str], n: int = 6) -> str:
    """没连 Apple Music、也没投过票：从它记得的 TA 的事里猜几位歌手当种子。"""
    return ("下面是你记得的关于 TA 的几件事：\n" + "\n".join(f"- {x}" for x in notes) + "\n\n"
            f"按这些猜 {n} 位 TA 可能喜欢的歌手或乐队。只输出一个 JSON 数组，元素是歌手在 Apple Music 上的名字（用原文），不要解释："
            '\n["歌手1", "歌手2"]')


def parse_artist_list(text: str, limit: int = 12) -> list[str]:
    body = str(text or "")
    start, end = body.find("["), body.rfind("]")
    if start < 0 or end <= start:
        return []
    try:
        items = json.loads(body[start:end + 1])
    except Exception:
        return []
    out, seen = [], set()
    for x in items if isinstance(items, list) else []:
        name = str(x or "").strip()[:60]
        if name and name.lower() not in seen:
            seen.add(name.lower())
            out.append(name)
    return out[:limit]


def by_artist(item: dict, artist: str) -> bool:
    """按歌手找出来的也可能是别人（合辑、翻唱），只认署名里真有这个人的。"""
    want, full = artist.lower(), item.get("artist", "").lower()
    return full == want or full.startswith(want + " &") or any(a.lower() == want for a in split_artists(full))   # 「Tyler, The Creator」名字里就有逗号


def build_pool(candidates: list[dict], heard: set, recent_ids: set, scores: dict[str, int],
               limit: int = POOL_LIMIT, rng: random.Random | None = None) -> list[dict]:
    """candidates：{id, name, artist, album, artwork, preview, url, origin: familiar/new}。洗成今天的池子。"""
    rng = rng or random.Random()
    seen_titles, per_artist, kept = set(), {}, []
    for c in candidates:
        if not c.get("id") or c["id"] in recent_ids or _COVERISH.search(c.get("name", "")):
            continue
        if song_key(c.get("name", ""), c.get("artist", "")) in heard:
            continue
        names = split_artists(c.get("artist", ""))
        if any(scores.get(a.lower(), 0) <= BLOCK_SCORE for a in names):
            continue
        lead = (names[0] if names else "").lower()
        title = _VARIANT.sub("", c.get("name", "")).strip().lower()
        if (title, lead) in seen_titles or per_artist.get(lead, 0) >= PER_ARTIST:
            continue
        seen_titles.add((title, lead))
        per_artist[lead] = per_artist.get(lead, 0) + 1
        kept.append(c)
    # 熟歌手和新歌手掺着放：约三分之一熟、三分之二新
    familiar = [c for c in kept if c.get("origin") == "familiar"]
    new = [c for c in kept if c.get("origin") != "familiar"]
    rng.shuffle(familiar)
    rng.shuffle(new)
    want_familiar = min(len(familiar), max(limit // 3, limit - len(new)))
    pool = familiar[:want_familiar] + new[:limit - want_familiar]
    rng.shuffle(pool)
    return pool


def validate_picks(pool: list[dict], picks, n: int = PICKS_DEFAULT) -> tuple[list[dict], list[str]]:
    """它交上来的 [{id, why}]。返回 (合格的，错误说明)。有任何错误就整批不收。"""
    by_id = {p["id"]: p for p in pool}
    errors, out, seen = [], [], set()
    if not isinstance(picks, list) or len(picks) != n:
        return [], [f"要挑 {n} 首"]
    for i, p in enumerate(picks, 1):
        pid = str((p or {}).get("id") or "").strip()
        why = str((p or {}).get("why") or "").strip()
        if pid not in by_id:
            errors.append(f"第 {i} 首的编号「{pid}」不在今天的候选池里——只能从池子里挑")
        elif pid in seen:
            errors.append(f"第 {i} 首重复了")
        elif not why:
            errors.append(f"第 {i} 首没写为什么")
        elif len(why) > WHY_MAX:
            errors.append(f"第 {i} 首的理由太长了（{len(why)} 字，最多 {WHY_MAX}）")
        else:
            seen.add(pid)
            out.append({**by_id[pid], "why": why})
    return (out, []) if not errors else ([], errors)
