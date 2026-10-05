"""音乐第 4 步：接口（连接 / 断开、凭证不出接口、歌单、私选投票、手机报在听）。假的 Apple Music，不联网。测试用小满 / Mia。"""
from datetime import date, datetime, timedelta, timezone

from brain import context_line
from music import store as S
from music.apple import Song
from test_api import Env


def song(i, name="Always", artist="Daniel Caesar"):
    return Song(i, name, artist, "", f"https://art/{i}", f"https://p/{i}", f"https://music.apple.com/au/song/{i}")


class FakeMusic:
    def __init__(self):
        self.calls = []

    async def storefront(self, token):
        return "au" if token == "good" else None

    async def songs(self, ids, storefront, lang=None):
        self.calls.append((ids, storefront, lang))
        names = {"1": ("晴天", "周杰伦")} if lang else {"1": ("Sunny Day", "Jay Chou")}
        return [song(i, *names.get(i, ("x", "y"))) for i in ids]


def env(pool):
    e = Env(pool)
    e.deps.music = FakeMusic()
    return e


async def test_link_unlink_and_token_never_leaves(pool):
    e = env(pool)
    t = await e.login()
    async with e.client(t) as c:
        assert (await c.get("/me/music")).json()["platform"] is None
        r = await c.put("/me/music", json={"platform": "apple", "user_token": "bad"})
        assert r.status_code == 400 and "没连上" in r.json()["detail"]
        r = await c.put("/me/music", json={"platform": "apple", "user_token": "good"})
        assert (r.json()["platform"], r.json()["linked"], r.json()["storefront"], r.json()["picks_n"]) == ("apple", True, "au", 3)
        assert "good" not in (await c.get("/me/music")).text
        assert (await c.put("/me/music", json={"platform": "netease"})).json()["linked"] is False
        r = (await c.put("/me/music", json={"platform": "apple", "storefront": "AU"})).json()   # 没会员：只存平台 + 区
        assert (r["platform"], r["linked"], r["storefront"]) == ("apple", False, "au")
        assert (await c.put("/me/music", json={"platform": "apple", "storefront": "../x"})).json()["storefront"] == ""
        assert (await c.put("/me/music", json={"platform": "walkman"})).status_code == 400
        assert (await c.delete("/me/music")).status_code == 204
        assert (await c.get("/me/music")).json()["platform"] is None


async def test_no_musickit_key_says_so(pool):
    e = Env(pool)                                       # deps.music 没配
    t = await e.login()
    async with e.client(t) as c:
        r = await c.put("/me/music", json={"platform": "apple", "user_token": "good"})
        assert r.status_code == 503
        assert (await c.put("/me/music", json={"platform": "qq"})).status_code == 200    # 别的平台不用钥匙


async def test_shelf_picks_and_votes_are_per_account(pool):
    e = env(pool)
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        me = (await c.get("/me")).json()["id"]
        from uuid import UUID
        acc = UUID(me)
        await S.shelve(pool, acc, song("1"), source="share", why="我们的歌")
        day = date(2026, 10, 1)
        await S.save_picks(pool, acc, day, [(song("2", "Good Days", "SZA"), "像周日早上")])
        assert [x["name"] for x in (await c.get("/music/shelf")).json()] == ["Always"]
        picks = (await c.get("/music/picks", params={"day": "2026-10-01"})).json()
        assert [(p["name"], p["why"]) for p in picks] == [("Good Days", "像周日早上")]
        r = await c.post("/music/picks/2026-10-01/0/vote", json={"vote": "up", "stars": 5, "reason": "好听"})
        assert (r.json()["vote"], r.json()["stars"]) == ("up", 5)
        assert (await c.post("/music/picks/2026-10-01/7/vote", json={"vote": "up"})).status_code == 404
        assert (await c.post("/music/picks/2026-10-01/0/vote", json={"vote": "love"})).status_code == 404
    async with e.client(other) as c:
        assert (await c.get("/music/shelf")).json() == []
        assert (await c.get("/music/picks", params={"day": "2026-10-01"})).json() == []
        assert (await c.post("/music/picks/2026-10-01/0/vote", json={"vote": "down"})).status_code == 404


async def test_phone_reports_now_playing(pool):
    e = env(pool)
    now = datetime(2026, 10, 1, 7, 0, tzinfo=timezone.utc)
    e.deps.now = lambda: now
    t = await e.login()
    async with e.client(t) as c:
        r = await c.post("/music/now", json={"song_id": "1", "name": "晴天", "artist": "周杰伦", "playing": True})
        assert r.status_code == 204
        from uuid import UUID
        items = await context_line.load(pool, UUID((await c.get("/me")).json()["id"]))
        assert items["music"][0] == {"song_id": "1", "name": "晴天", "artist": "周杰伦", "playing": True}
        line = context_line.render(items, now + timedelta(minutes=1), "Asia/Singapore", "zh")
        assert "在听" in line and "晴天" in line
        assert "晴天" not in context_line.render(items, now + timedelta(minutes=30), "Asia/Singapore", "zh")   # 过了 20 分钟不给
        assert (await c.post("/music/now", json={"name": ""})).status_code == 400
        await c.post("/music/now", json={"song_id": "1", "name": "晴天", "artist": "周杰伦", "playing": True, "position_s": 42.37})
        items = await context_line.load(pool, UUID((await c.get("/me")).json()["id"]))
        assert items["music"][0]["position_s"] == 42.4                     # 耳朵：放到第几秒（09-30）
        await c.post("/music/now", json={"song_id": "1", "name": "晴天", "playing": True, "position_s": "乱写"})
        items = await context_line.load(pool, UUID((await c.get("/me")).json()["id"]))
        assert "position_s" not in items["music"][0]


async def test_song_lookup_uses_chinese_names_for_english_only_storefront(pool):
    e = env(pool)
    t = await e.login()
    async with e.client(t) as c:
        await c.put("/me/music", json={"platform": "apple", "user_token": "good"})
        r = (await c.get("/music/song/1")).json()
        assert (r["name"], r["artist"], r["url"]) == ("晴天", "周杰伦", "https://music.apple.com/au/song/1")
