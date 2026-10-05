"""没 MusicKit 钥匙时找歌走 iTunes 公开搜索（10-05，Mele Host）。假接口回的是 iTunes 真实的字段形状。"""
from music.itunes import ITunesMusic

TRACK = {"wrapperType": "track", "kind": "song", "trackId": 1440858045, "artistId": 300117743, "trackName": "晴天",
         "artistName": "周杰伦", "collectionName": "叶惠美", "artworkUrl100": "https://x/100x100bb.jpg",
         "previewUrl": "https://p/a.m4a", "trackViewUrl": "https://music.apple.com/x", "trackExplicitness": "notExplicit",
         "trackTimeMillis": 269000}


def fake(routes):
    calls = []

    async def get(url, params):
        calls.append((url.rsplit("/", 1)[-1], params))
        return 200, {"results": routes[url.rsplit("/", 1)[-1] + ":" + params.get("entity", "")]}
    return get, calls


async def test_search_lookup_and_top_songs():
    other = {**TRACK, "trackId": 1, "artistId": 999, "trackName": "合辑里别人的歌"}
    get, calls = fake({"search:song": [TRACK], "search:musicArtist": [{"wrapperType": "artist", "artistId": 300117743, "artistName": "周杰倫"}],
                       "lookup:song": [{"wrapperType": "artist", "artistId": 300117743}, TRACK, other]})
    am = ITunesMusic(get=get)
    s = (await am.search_songs("晴天", "au"))[0]
    assert (s.id, s.name, s.artist, s.artwork, s.preview, s.duration_ms) == ("1440858045", "晴天", "周杰伦", "https://x/300x300bb.jpg", "https://p/a.m4a", 269000)
    assert (await am.search_artists("周杰伦", "au"))[0].id == "300117743"
    assert [x.name for x in await am.artist_top_songs("300117743", "au")] == ["晴天"]        # 别人的歌不算
    assert [x.id for x in await am.songs(["1440858045"], "au")] == ["1440858045"]
    assert await am.similar_artists("300117743", "au") == [] and await am.storefront("tok") is None
    assert calls[0][1]["country"] == "au"


async def test_errors_come_back_empty():
    async def boom(url, params):
        raise RuntimeError("offline")
    assert await ITunesMusic(get=boom).search_songs("x", "au") == []
