"""Lumi 分享一首歌之前先定是哪一首（09-30，音乐第 2 步）。移植自之前自用的 App 的中继 music_share.py（12Leyin21 写的），
Spotify 换成 Apple Music：搜到的都能放（没有「放不了」那档）、歌手用「&」「,」分隔；
加了中文名：澳洲这类只有英文的区，《晴天》叫 Sunny Day - Jay Chou，拿新加坡区的中文名（alt）一起比，卡上显示中文名。

纯逻辑：给一串搜索结果，判定 ready / needs_choice / error。不碰网络。"""
from __future__ import annotations

import re

from .apple import Song

MIN_COVERAGE = 0.6   # 低于这个就当没搜到——曲库总会给点什么，不能拿不沾边的充数
ZH_STOREFRONTS = {"cn", "hk", "tw", "mo", "sg"}          # 这几个区的曲库有中文名

_VARIANT = re.compile(r"\s*[\(\[（【-].*?(live|remaster|version|edit|mix|acoustic|demo|instrumental|现场|版).*$", re.I)
_COVERISH = re.compile(r"(伴奏|钢琴版|鋼琴版|翻唱|原唱|cover|karaoke|instrumental|piano ver|lofi|remix|sped up|slowed)", re.I)
_CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")
_SPLIT = re.compile(r"\s*(?:[、,，/]|&| feat\. | ft\. )\s*", re.I)


def localize_lang(storefront: str, lang: str) -> tuple[str, str] | None:
    """TA 用中文、TA 那个区的曲库没有中文名：去哪个区、用什么语言借中文名。不用借 = None。"""
    if lang != "zh" or (storefront or "").lower() in ZH_STOREFRONTS:
        return None
    return "sg", "zh-Hans-CN"


def _norm_title(name: str) -> str:
    return _VARIANT.sub("", (name or "").strip()).strip().lower()


def _words(query: str) -> list[str]:
    return [w for w in re.split(r"[\s\-–—·,，、:：/]+", (query or "").lower()) if w]


def _first_artist(artist: str) -> str:
    return _SPLIT.split(artist or "")[0].strip()


def _names(song: Song, alt: Song | None) -> list[tuple[str, str]]:
    return [(song.name, song.artist)] + ([(alt.name, alt.artist)] if alt else [])


def _score(song: Song, alt: Song | None, words: list[str]) -> int:
    return max(sum(1 for w in words if w in f"{n} {a}".lower()) for n, a in _names(song, alt))


def _matches_one(name: str, artist: str, query: str) -> bool:
    """沾边才算搜到。拉丁字母按整词算（按字母算，乱打一串 zzqqxx 也能撞上 Zzyzx），中日韩按字算（中文不空格）；
    或者歌名（去掉括号）整个写在查询里。"""
    title = re.sub(r"\s*[\(\[（【].*$", "", name or "").strip().lower()
    if title and title in (query or "").lower():
        return True
    hay = f"{name} {artist}".lower()
    latin = [w for w in _words(_CJK.sub(" ", query)) if w]
    cjk = set(_CJK.findall(query or ""))
    ok_latin = not latin or sum(1 for w in latin if w in hay) * 2 >= len(latin)
    ok_cjk = not cjk or len(cjk & set(hay)) / len(cjk) >= MIN_COVERAGE
    return bool(latin or cjk) and ok_latin and ok_cjk


def pick_share(query: str, songs: list[Song], alt: dict[str, Song] | None = None) -> dict:
    """songs：TA 那个区的搜索结果（曲库自己的热度顺序）；alt：同编号的中文名版本。
    ready → {"song": 放 / 链接用的, "display": 卡上显示的}；needs_choice → {"candidates": [...]}；error → {"code": "NOT_FOUND"}。"""
    alt = alt or {}
    matching = [x for x in songs if x.id and any(_matches_one(n, a, query) for n, a in _names(x, alt.get(x.id)))]
    if not matching:
        return {"status": "error", "code": "NOT_FOUND"}
    words = _words(query)
    order = {x.id: n for n, x in enumerate(songs)}
    # 排序：查询词命中多的 > 不是翻唱 / 伴奏 / 钢琴版的 > 曲库原本的热度顺序（原唱一般在前）
    score = lambda x: _score(x, alt.get(x.id), words)                          # noqa: E731
    matching.sort(key=lambda x: (-score(x), 1 if _COVERISH.search(x.name) else 0, order[x.id]))
    best = matching[0]
    top = [x for x in matching if score(x) == score(best)]
    # 同名不同歌手：查询里没写到哪位歌手，就让它挑，不闭眼拿第一个；翻唱 / 伴奏不算另一首同名歌
    same_title = [x for x in top if _norm_title(x.name) == _norm_title(best.name)]
    originals = [x for x in same_title if not _COVERISH.search(x.name)]
    same_title = originals or same_title
    firsts: list[str] = []
    for x in same_title:
        if (f := _first_artist(x.artist)) and f not in firsts:
            firsts.append(f)
    q = (query or "").lower()
    named = any(f.lower() in q for f in firsts) or any(
        _first_artist(alt[x.id].artist).lower() in q for x in same_title if x.id in alt)
    if len(firsts) >= 2 and not named:
        seen, cands = set(), []
        for x in same_title:
            if (f := _first_artist(x.artist)) not in seen:
                seen.add(f)
                cands.append(alt.get(x.id) or x)
        return {"status": "needs_choice", "candidates": cands[:4]}
    return {"status": "ready", "song": best, "display": alt.get(best.id) or best}


def card_text(song: Song, why: str) -> str:
    """歌卡上它那句话；没写就是歌名。"""
    why = (why or "").strip()
    return why or f"🎵 《{song.name}》 — {song.artist}"
