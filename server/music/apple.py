"""Apple Music 接口（09-30，音乐第 1 步）。开发者凭证用 MusicKit 钥匙（ES256，12 小时一换）；
带用户凭证的（最近在听、常听）要 TA 在手机上连过 Apple Music。

一起听是甜点，不能影响主餐：任何一步出错 / 超时都回空（[] / None），不抛。"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass

import httpx

from push import es256

log = logging.getLogger(__name__)
API = "https://api.music.apple.com/v1"
TOKEN_LIFE = 12 * 3600
ART = 300                       # 封面边长（像素）


@dataclass(frozen=True)
class Song:
    id: str
    name: str
    artist: str
    album: str
    artwork: str
    preview: str
    url: str
    explicit: bool = False
    duration_ms: int = 0

    def as_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "artist": self.artist, "album": self.album,
                "artwork": self.artwork, "preview": self.preview, "url": self.url}


@dataclass(frozen=True)
class Artist:
    id: str
    name: str


async def _httpx_get(url: str, params: dict, headers: dict) -> tuple[int, dict]:
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(url, params=params, headers=headers)
    return r.status_code, (r.json() if r.content else {})


def _song(d: dict) -> Song | None:
    a = d.get("attributes") or {}
    if d.get("type", "songs") != "songs" or not a.get("name"):
        return None
    art = ((a.get("artwork") or {}).get("url") or "").replace("{w}", str(ART)).replace("{h}", str(ART))
    previews = a.get("previews") or [{}]
    return Song(str(d.get("id")), a["name"], a.get("artistName", ""), a.get("albumName", ""), art,
                previews[0].get("url", ""), a.get("url", ""), a.get("contentRating") == "explicit",
                int(a.get("durationInMillis") or 0))


class AppleMusic:
    def __init__(self, key_pem: bytes, key_id: str, team_id: str, *, get=None, clock=None):
        self.key_pem, self.key_id, self.team_id = key_pem, key_id, team_id
        self.get = get or _httpx_get
        self.clock = clock or time.time
        self._token: tuple[str, float] | None = None

    def _dev_token(self) -> str:
        now = self.clock()
        if self._token is None or now - self._token[1] > TOKEN_LIFE - 3600:
            self._token = (es256.sign(self.key_pem, self.key_id,
                                      {"iss": self.team_id, "iat": int(now), "exp": int(now) + TOKEN_LIFE}), now)
        return self._token[0]

    async def _call(self, path: str, params: dict | None = None, user_token: str | None = None) -> dict | None:
        headers = {"Authorization": f"Bearer {self._dev_token()}"}
        if user_token:
            headers["Music-User-Token"] = user_token
        try:
            status, body = await self.get(f"{API}{path}", params or {}, headers)
        except Exception as e:                                   # noqa: BLE001 —— 甜点，出错回空
            log.warning("apple music %s failed: %r", path, e)
            return None
        if status != 200:
            log.info("apple music %s -> %s", path, status)
            return None
        return body

    async def search_songs(self, term: str, storefront: str, limit: int = 5, lang: str | None = None) -> list[Song]:
        body = await self._call(f"/catalog/{storefront}/search",
                                {"term": term, "types": "songs", "limit": limit, **({"l": lang} if lang else {})})
        data = (((body or {}).get("results") or {}).get("songs") or {}).get("data") or []
        return [s for d in data if (s := _song(d))]

    async def songs(self, ids: list[str], storefront: str, lang: str | None = None) -> list[Song]:
        """按编号查；lang 给了就按那个语言回名字（去新加坡区借中文名用，见 share.localize_lang）。"""
        if not ids:
            return []
        body = await self._call(f"/catalog/{storefront}/songs", {"ids": ",".join(ids), **({"l": lang} if lang else {})})
        return [s for d in (body or {}).get("data") or [] if (s := _song(d))]

    async def search_artists(self, term: str, storefront: str, limit: int = 1) -> list[Artist]:
        body = await self._call(f"/catalog/{storefront}/search", {"term": term, "types": "artists", "limit": limit})
        data = (((body or {}).get("results") or {}).get("artists") or {}).get("data") or []
        return [Artist(str(d["id"]), (d.get("attributes") or {}).get("name", "")) for d in data]

    async def similar_artists(self, artist_id: str, storefront: str, limit: int = 10) -> list[Artist]:
        body = await self._call(f"/catalog/{storefront}/artists/{artist_id}/view/similar-artists", {"limit": limit})
        return [Artist(str(d["id"]), (d.get("attributes") or {}).get("name", "")) for d in (body or {}).get("data") or []]

    async def artist_top_songs(self, artist_id: str, storefront: str, limit: int = 10) -> list[Song]:
        body = await self._call(f"/catalog/{storefront}/artists/{artist_id}/view/top-songs", {"limit": limit})
        return [s for d in (body or {}).get("data") or [] if (s := _song(d))]

    # ── 要 TA 的用户凭证 ──

    async def recent_tracks(self, user_token: str, limit: int = 10) -> list[Song]:
        body = await self._call("/me/recent/played/tracks", {"limit": limit, "types": "songs"}, user_token)
        return [s for d in (body or {}).get("data") or [] if (s := _song(d))]

    async def heavy_rotation_artists(self, user_token: str) -> list[str]:
        """「最近常听」回的是专辑 / 歌单：取专辑的歌手（歌单不算，它的「歌手」是策展人）。"""
        body = await self._call("/me/history/heavy-rotation", {"limit": 10}, user_token)
        out: list[str] = []
        for d in (body or {}).get("data") or []:
            name = (d.get("attributes") or {}).get("artistName")
            if d.get("type") == "albums" and name and name not in out:
                out.append(name)
        return out

    async def storefront(self, user_token: str) -> str | None:
        """TA 的 Apple Music 在哪个区（顺便验用户凭证是真的）。"""
        body = await self._call("/me/storefront", None, user_token)
        data = (body or {}).get("data") or []
        return str(data[0]["id"]) if data else None
