"""没配 MusicKit 钥匙时找歌走 iTunes 公开搜索（10-05 Tilia：Mele Host 的用户没有开发者钥匙，推歌、歌卡整个用不了；
Lite 本机一直是这么找的，ios/Lite/LocalMusic.swift）。编号就是 Apple Music 的编号，歌卡、试听、「耳朵」照用。

跟 AppleMusic 同一套接口；没有的两样：相似歌手（回空，私选会请模型报名字）、要用户凭证的（最近在听 / 常听 / 哪个区，回空）。
任何一步出错 / 超时都回空，不抛。"""
from __future__ import annotations

import logging

import httpx

from .apple import Artist, Song

log = logging.getLogger(__name__)
API = "https://itunes.apple.com"
ART = "300x300bb"


async def _httpx_get(url: str, params: dict) -> tuple[int, dict]:
    async with httpx.AsyncClient(timeout=10, headers={"User-Agent": "Mele/1.0"}) as c:
        r = await c.get(url, params=params)
    return r.status_code, (r.json() if r.content else {})


def _song(x: dict) -> Song | None:
    if x.get("wrapperType") != "track" or x.get("kind") not in (None, "song") or not x.get("trackId") or not x.get("trackName"):
        return None
    art = (x.get("artworkUrl100") or "").replace("100x100bb", ART)
    return Song(str(x["trackId"]), x["trackName"], x.get("artistName", ""), x.get("collectionName", ""), art,
                x.get("previewUrl", ""), x.get("trackViewUrl", ""), x.get("trackExplicitness") == "explicit",
                int(x.get("trackTimeMillis") or 0))


class ITunesMusic:
    user_features = False          # 没有用户凭证那一套：连 Apple Music 时不去验凭证

    def __init__(self, *, get=None):
        self.get = get or _httpx_get

    async def _call(self, path: str, params: dict) -> list[dict]:
        try:
            status, body = await self.get(f"{API}/{path}", params)
        except Exception as e:                                   # noqa: BLE001 —— 甜点，出错回空
            log.warning("itunes %s failed: %r", path, e)
            return []
        if status != 200:
            log.info("itunes %s -> %s", path, status)
            return []
        return (body or {}).get("results") or []

    async def search_songs(self, term: str, storefront: str, limit: int = 5, lang: str | None = None) -> list[Song]:
        got = await self._call("search", {"term": term, "entity": "song", "limit": limit, "country": storefront})
        return [s for x in got if (s := _song(x))]

    async def songs(self, ids: list[str], storefront: str, lang: str | None = None) -> list[Song]:
        if not ids:
            return []
        got = await self._call("lookup", {"id": ",".join(ids), "entity": "song", "country": storefront})
        by_id = {s.id: s for x in got if (s := _song(x))}
        return [by_id[i] for i in ids if i in by_id]

    async def search_artists(self, term: str, storefront: str, limit: int = 1) -> list[Artist]:
        got = await self._call("search", {"term": term, "entity": "musicArtist", "limit": limit, "country": storefront})
        return [Artist(str(x["artistId"]), x.get("artistName", "")) for x in got if x.get("artistId")]

    async def similar_artists(self, artist_id: str, storefront: str, limit: int = 10) -> list[Artist]:
        return []

    async def artist_top_songs(self, artist_id: str, storefront: str, limit: int = 10) -> list[Song]:
        # 按歌手编号认（搜出来叫「周杰倫」，歌上署名是 Jay Chou）；合辑、别人的歌不算
        got = await self._call("lookup", {"id": artist_id, "entity": "song", "limit": limit, "country": storefront})
        return [s for x in got if str(x.get("artistId")) == str(artist_id) and (s := _song(x))]

    async def recent_tracks(self, user_token: str, limit: int = 10) -> list[Song]:
        return []

    async def heavy_rotation_artists(self, user_token: str) -> list[str]:
        return []

    async def storefront(self, user_token: str) -> str | None:
        return None
