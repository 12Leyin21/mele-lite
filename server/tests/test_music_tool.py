"""音乐第 5 步：Lumi 的 music 工具。share：曲库里找到才发歌卡、进歌单；needs_choice / 没找到说清楚；now：TA 在听什么。
假的 Apple Music，不联网。测试用小满。"""
from datetime import timedelta

from brain import context_line
from brain.tools import tool_specs
from music import store as S
from music.apple import Song
from test_wake_turn import NOW, go, setup


def song(i, name, artist):
    return Song(i, name, artist, "", f"https://art/{i}", f"https://p/{i}", f"https://music.apple.com/au/song/{i}")


class FakeMusic:
    CATALOG = [song("1", "Sunny Day", "Jay Chou"), song("2", "Always", "Daniel Caesar"), song("3", "Always", "Bon Jovi")]
    ZH = {"1": song("1", "晴天", "周杰伦")}

    async def search_songs(self, term, storefront, limit=5, lang=None):
        t = term.lower()
        return [s for s in self.CATALOG if s.name.lower() in t or t in s.name.lower()
                or any(z.name in term for k, z in self.ZH.items() if k == s.id)]

    async def songs(self, ids, storefront, lang=None):
        return [self.ZH[i] for i in ids if i in self.ZH] if lang else [s for s in self.CATALOG if s.id in ids]


def share(query, why=""):
    return {"calls": [("music", {"action": "share", "query": query, "why": why})]}


async def test_share_found_makes_a_song_card_and_shelves_it(pool):
    deps, scope, model = await setup(pool, [share("晴天 周杰伦", "下雨天听这个"), "给你～"])
    deps.music = FakeMusic()
    await S.link(pool, None, scope.account, platform="netease")          # 用网易云的人也能收到歌卡
    await pool.execute("UPDATE music_links SET storefront = 'au' WHERE account_id = $1", scope.account)
    out, ev = await go(deps, scope, "下雨了想听歌")
    [card] = [e for e in ev if e["type"] == "card"]
    assert (card["kind"], card["text"], card["private"]) == ("song", "下雨天听这个", False)
    d = card["data"]
    assert (d["id"], d["name"], d["artist"], d["url"]) == ("1", "晴天", "周杰伦", "https://music.apple.com/au/song/1")
    assert d["preview"] and not d.get("queue")
    assert [x["name"] for x in await S.shelf(pool, scope.account)] == ["晴天"]
    assert "晴天" in model.requests[1].rounds[0].results[0]


async def test_ambiguous_and_missing_songs_are_explained_not_carded(pool):
    deps, scope, model = await setup(pool, [share("Always"), share("zzqqxx"), "好"])
    deps.music = FakeMusic()
    out, ev = await go(deps, scope, "来首歌")
    assert [e for e in ev if e["type"] == "card"] == []
    first, second = model.requests[1].rounds[0].results[0], model.requests[2].rounds[1].results[0]
    assert "Daniel Caesar" in first and "Bon Jovi" in first and "谁唱" in first
    assert "没找到" in second
    assert await S.shelf(pool, scope.account) == []


async def test_card_asks_phone_to_queue_while_listening_together(pool):
    deps, scope, _ = await setup(pool, [share("Always Daniel Caesar"), "放给你"])
    deps.music = FakeMusic()
    await context_line.save(pool, scope.account, "music", {"name": "Blessed", "artist": "Daniel Caesar", "playing": True},
                            NOW - timedelta(minutes=3))
    _, ev = await go(deps, scope, "接着放一首")
    [card] = [e for e in ev if e["type"] == "card"]
    assert card["data"]["queue"] is True


async def test_now_and_no_key(pool):
    deps, scope, model = await setup(pool, [{"calls": [("music", {"action": "now"})]}, {"calls": [("music", {"action": "now"})]}, "嗯"])
    await context_line.save(pool, scope.account, "music", {"name": "晴天", "artist": "周杰伦", "playing": False},
                            NOW - timedelta(minutes=5))
    await go(deps, scope, "猜我在听什么")
    assert "晴天" in model.requests[1].rounds[0].results[0]
    deps2, scope2, model2 = await setup(pool, [share("晴天"), "嗯"])            # 没配 MusicKit 钥匙
    await go(deps2, scope2, "来首歌")
    assert "Apple Music" in model2.requests[1].rounds[0].results[0]


def test_not_in_incognito():
    assert "music" in [t.name for t in tool_specs()]
    assert "music" not in [t.name for t in tool_specs(incognito=True)]
