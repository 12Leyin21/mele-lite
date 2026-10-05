"""找歌的网络那半（09-30）：搜 TA 那个区 + 需要时去别的区借中文名，交给 share.pick_share 定哪一首。"""
from __future__ import annotations

from .apple import Song
from .share import localize_lang, pick_share

DEFAULT_STOREFRONT = "us"


async def alt_names(am, ids: list[str], storefront: str, lang: str) -> dict[str, Song]:
    """TA 那个区没有中文名时，同编号去新加坡区按中文再查一次；不用借 = {}。"""
    where = localize_lang(storefront, lang)
    if not where or not ids:
        return {}
    return {s.id: s for s in await am.songs(ids, where[0], lang=where[1])}


async def find_song(am, query: str, storefront: str, lang: str, limit: int = 8) -> dict:
    """搜 → 借中文名 → 定哪一首。返回 pick_share 的结果。"""
    sf = storefront or DEFAULT_STOREFRONT
    found = await am.search_songs(query, sf, limit)
    return pick_share(query, found, await alt_names(am, [s.id for s in found], sf, lang))


def shown(song: Song, alt: Song | None) -> dict:
    """卡上用的：名字按 TA 的语言（借来的中文名），链接 / 试听 / 封面用 TA 那个区的。"""
    d = song.as_dict()
    if alt:
        d["name"], d["artist"] = alt.name, alt.artist
    return d
