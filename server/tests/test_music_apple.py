"""Apple Music 接口（音乐第 1 步）：开发者凭证、解析歌 / 歌手、用户凭证、出错回空。不联网，用假的 get。"""
import base64
import json

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from music.apple import AppleMusic, Song
from push import es256

KEY = ec.generate_private_key(ec.SECP256R1())
PEM = KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def song_json(i="1", name="Always", artist="Daniel Caesar", explicit=False):
    return {"id": i, "type": "songs", "attributes": {
        "name": name, "artistName": artist, "albumName": "Freudian", "url": f"https://music.apple.com/au/song/{i}",
        "artwork": {"url": "https://is1.mzstatic.com/x/{w}x{h}bb.jpg"},
        "previews": [{"url": f"https://audio.example/{i}.m4a"}], **({"contentRating": "explicit"} if explicit else {})}}


class FakeGet:
    def __init__(self, routes):
        self.routes, self.calls = routes, []

    async def __call__(self, url, params, headers):
        self.calls.append((url, params, headers))
        for tail, reply in self.routes.items():
            if url.endswith(tail):
                return reply
        return 404, {}


def test_es256_token_verifies_and_carries_kid_and_issuer():
    tok = es256.sign(PEM, "KID123", {"iss": "TEAM", "iat": 1000, "exp": 2000})
    h, c, s = tok.split(".")
    assert json.loads(_unb64(h)) == {"alg": "ES256", "kid": "KID123"}
    assert json.loads(_unb64(c)) == {"iss": "TEAM", "iat": 1000, "exp": 2000}
    raw = _unb64(s)
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    KEY.public_key().verify(der, f"{h}.{c}".encode(), ec.ECDSA(hashes.SHA256()))      # 不抛 = 签对了


async def test_search_parses_songs_and_sends_developer_token():
    get = FakeGet({"/catalog/au/search": (200, {"results": {"songs": {"data": [song_json(), song_json("2", "Blessed", explicit=True)]}}})})
    am = AppleMusic(PEM, "KID", "TEAM", get=get, clock=lambda: 1000.0)
    got = await am.search_songs("Daniel Caesar", "au", limit=2)
    assert got[0] == Song("1", "Always", "Daniel Caesar", "Freudian", "https://is1.mzstatic.com/x/300x300bb.jpg",
                          "https://audio.example/1.m4a", "https://music.apple.com/au/song/1", False)
    assert got[1].explicit
    url, params, headers = get.calls[0]
    assert params == {"term": "Daniel Caesar", "types": "songs", "limit": 2}
    assert headers["Authorization"].startswith("Bearer ") and "Music-User-Token" not in headers


async def test_token_is_reused_until_close_to_expiry():
    get = FakeGet({"/search": (200, {"results": {}})})
    t = {"now": 1000.0}
    am = AppleMusic(PEM, "KID", "TEAM", get=get, clock=lambda: t["now"])
    await am.search_songs("a", "au")
    await am.search_songs("b", "au")
    t["now"] += 13 * 3600
    await am.search_songs("c", "au")
    tokens = [c[2]["Authorization"] for c in get.calls]
    assert tokens[0] == tokens[1] != tokens[2]


async def test_artists_similar_and_top_songs():
    get = FakeGet({
        "/search": (200, {"results": {"artists": {"data": [{"id": "9", "attributes": {"name": "Daniel Caesar"}}]}}}),
        "/artists/9/view/similar-artists": (200, {"data": [{"id": "7", "attributes": {"name": "SZA"}}]}),
        "/artists/7/view/top-songs": (200, {"data": [song_json("3", "Good Days", "SZA")]}),
    })
    am = AppleMusic(PEM, "KID", "TEAM", get=get)
    [a] = await am.search_artists("Daniel Caesar", "au")
    assert (a.id, a.name) == ("9", "Daniel Caesar")
    [s] = await am.similar_artists("9", "au")
    assert s.name == "SZA"
    assert [x.name for x in await am.artist_top_songs("7", "au")] == ["Good Days"]


async def test_user_endpoints_send_music_user_token():
    get = FakeGet({"/me/recent/played/tracks": (200, {"data": [song_json()]}),
                   "/me/history/heavy-rotation": (200, {"data": [
                       {"id": "p1", "type": "playlists", "attributes": {"name": "x"}},
                       {"id": "a1", "type": "albums", "attributes": {"name": "Freudian", "artistName": "Daniel Caesar"}}]}),
                   "/me/storefront": (200, {"data": [{"id": "au"}]})})
    am = AppleMusic(PEM, "KID", "TEAM", get=get)
    [t] = await am.recent_tracks("USERTOKEN")
    assert t.name == "Always" and get.calls[-1][2]["Music-User-Token"] == "USERTOKEN"
    assert await am.heavy_rotation_artists("USERTOKEN") == ["Daniel Caesar"]     # 常听的是专辑 / 歌单：取专辑的歌手，歌单不算
    assert await am.storefront("USERTOKEN") == "au"


async def test_errors_and_timeouts_come_back_empty():
    async def boom(url, params, headers):
        raise TimeoutError
    am = AppleMusic(PEM, "KID", "TEAM", get=boom)
    assert await am.search_songs("x", "au") == []
    assert await am.storefront("T") is None
    am = AppleMusic(PEM, "KID", "TEAM", get=FakeGet({}))           # 404
    assert await am.similar_artists("1", "au") == []
    am = AppleMusic(PEM, "KID", "TEAM", get=FakeGet({"/me/storefront": (401, {})}))
    assert await am.storefront("bad") is None


async def test_songs_by_id_in_another_language():
    get = FakeGet({"/catalog/sg/songs": (200, {"data": [song_json("1", "晴天", "周杰伦")]})})
    am = AppleMusic(PEM, "KID", "TEAM", get=get)
    [x] = await am.songs(["1"], "sg", lang="zh-Hans-CN")
    assert x.name == "晴天" and get.calls[0][1] == {"ids": "1", "l": "zh-Hans-CN"}
    assert await am.songs([], "sg") == []
