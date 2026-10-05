"""音乐第 6 步（下）：每日私选。选了平台就挂钟 → 起床后半小时建池子 → 叫醒 Lumi 挑 → 歌卡跟着消息进聊天流 → 挂明天的。
假曲库、假模型，不联网。测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import UUID
from zoneinfo import ZoneInfo

from brain import archive
from music.apple import Artist, Song
from patrol.loop import tick_once
from test_api import Env

TZ_SG = ZoneInfo("Asia/Singapore")
T0 = datetime(2026, 10, 1, 6, 0, tzinfo=TZ_SG).astimezone(timezone.utc)
SIMILAR = ["SZA", "GIVĒON", "Brent Faiyaz", "Steve Lacy", "Frank Ocean"]


def s(i, name, artist):
    return Song(i, name, artist, "", f"https://art/{i}", f"https://p/{i}", f"https://music.apple.com/au/song/{i}")


class FakeCatalog:
    async def storefront(self, token):
        return "au"

    async def heavy_rotation_artists(self, token):
        return ["Daniel Caesar"]

    async def recent_tracks(self, token, limit=10):
        return [s("r1", "Always", "Daniel Caesar")]

    async def search_artists(self, name, sf, limit=1):
        return [Artist(name.lower(), name)]

    async def similar_artists(self, artist_id, sf, limit=10):
        return [Artist(a.lower(), a) for a in SIMILAR] if artist_id == "daniel caesar" else []

    async def songs(self, ids, sf, lang=None):                     # 新加坡区的中文名：只有这一首有
        return [s("daniel caesar-1", "丹尼尔的歌", "丹尼尔·凯撒")] if lang and "daniel caesar-1" in ids else []

    async def artist_top_songs(self, artist_id, sf, limit=10):
        name = "Daniel Caesar" if artist_id == "daniel caesar" else next(a for a in SIMILAR if a.lower() == artist_id)
        return [s(f"{artist_id}-{k}", f"{name} song {k}", name) for k in range(3)][:limit]


def picks(*pairs):
    return {"calls": [("music", {"action": "picks", "picks": [{"id": i, "why": w} for i, w in pairs]})]}


async def _env(pool, script):
    e = Env(pool, script)
    e.deps.music = FakeCatalog()
    clock = {"now": T0}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    return e, t, clock


async def test_morning_picks_end_to_end(pool):
    e, t, clock = await _env(pool, [
        picks(("sza-0", "像周日早上"), ("nobody-9", "编的"), ("givēon-1", "低一点的声音")),     # 编号不在池子里：整批打回
        picks(("sza-0", "像周日早上"), ("daniel caesar-2", "你常听他，这首你没放过"), ("givēon-1", "低一点的声音")),
        "早安，今天给你挑了三首，第一首适合刚醒"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore", "morning_on": False, "sleep_to": "07:00",
                                                                        "heartbeat_on": False, "reply_wait": 0}})
        r = (await c.put("/me/music", json={"platform": "apple", "user_token": "good"})).json()
        assert r["picks_n"] == 3
        at = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'picks'")
        assert at.astimezone(TZ_SG).strftime("%H:%M") == "07:30"
        await tick_once(e.deps, e.rooms)                                   # 06:00：还没到
        assert e.model.requests == []
        clock["now"] = T0 + timedelta(minutes=91)                          # 07:31
        await tick_once(e.deps, e.rooms)
        wake = "\n".join(m.text for m in e.model.requests[0].messages)
        assert "今天的私选候选备好了" in wake and "#sza-0 SZA song 0 - SZA（新）" in wake
        assert "#daniel caesar-1 丹尼尔的歌 - 丹尼尔·凯撒（熟）" in wake and "挑 3 首" in wake   # 借了中文名
        assert "没收" in e.model.requests[1].rounds[0].results[0]
        acc = UUID((await c.get("/me")).json()["id"])
        got = (await c.get("/music/picks", params={"day": "2026-10-01"})).json()
        assert [(p["song_id"], p["why"]) for p in got] == [("sza-0", "像周日早上"), ("daniel caesar-2", "你常听他，这首你没放过"),
                                                            ("givēon-1", "低一点的声音")]
        [msg] = [m for m in await archive.recent(pool, UUID(conv["id"]), 5) if m.role == "assistant"]
        assert "早安" in msg.text and [cd["kind"] for cd in msg.cards] == ["song", "song", "song"]
        assert msg.cards[0]["data"]["pick_day"] == "2026-10-01" and msg.cards[0]["data"]["pos"] == 0
        assert await pool.fetchval("SELECT count(*) FROM push_queue WHERE account_id = $1", acc) >= 1
        assert len((await c.get("/music/shelf")).json()) == 3
        nxt = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'picks'")
        assert nxt.astimezone(TZ_SG) == datetime(2026, 10, 2, 7, 30, tzinfo=TZ_SG)          # 明天的挂上了
        from patrol import store
        assert await store.wakes_since(pool, UUID(comp["id"]), T0) == 0                   # 不占每天醒来的份


async def test_picks_settings_and_nothing_to_go_on(pool):
    e, t, clock = await _env(pool, [])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore", "heartbeat_on": False, "morning_on": False}})
        assert (await c.patch("/me/music", json={"picks_n": 2})).status_code == 400           # 还没选平台
        await c.put("/me/music", json={"platform": "netease"})                              # 没连 Apple Music、没投过票、没记忆
        r = (await c.patch("/me/music", json={"picks_n": 2, "picks_at": "09:15"})).json()
        assert (r["picks_n"], r["picks_at"]) == (2, "09:15")
        at = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'picks'")
        assert at.astimezone(TZ_SG).strftime("%H:%M") == "09:15"
        assert (await c.patch("/me/music", json={"picks_at": "25:00"})).status_code == 400
        clock["now"] = datetime(2026, 10, 1, 9, 16, tzinfo=TZ_SG).astimezone(timezone.utc)
        await tick_once(e.deps, e.rooms)
        assert e.model.requests == []                                                     # 没种子：今天不推、不叫醒
        nxt = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'picks'")
        assert nxt.astimezone(TZ_SG) == datetime(2026, 10, 2, 9, 15, tzinfo=TZ_SG)
        await c.patch("/me/music", json={"picks_n": 0})                                    # 0 = 不推
        assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'picks'") == 0
        await c.patch("/me/music", json={"picks_n": 3})
        await c.delete("/me/music")
        assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'picks'") == 0
