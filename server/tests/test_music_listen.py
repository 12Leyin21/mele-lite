"""音乐第 7 步：Mele 关着时，巡逻每 5 分钟问一次 Apple「最近放了什么」，换歌了就进〔TA 那边〕（刚才在听）。
手机报的更准，20 分钟内报过就不拉。只拉连了 Apple Music、最近 12 小时开过 app 的。假曲库，测试用小满。"""
from datetime import datetime, timedelta, timezone

from cryptography.fernet import Fernet

from brain import accounts, archive, auth, context_line
from music import listen
from music import store as S
from music.apple import Song

NOW = datetime(2026, 10, 1, 10, 0, tzinfo=timezone.utc)
BOX = auth.KeyBox(Fernet.generate_key())


def s(i, name, artist):
    return Song(i, name, artist, "", "", "", "")


class FakeCatalog:
    def __init__(self):
        self.latest, self.asked = s("1", "Sunny Day", "Jay Chou"), 0

    async def recent_tracks(self, token, limit=10):
        self.asked += 1
        return [self.latest]

    async def songs(self, ids, sf, lang=None):
        return [s("1", "晴天", "周杰伦")] if lang and "1" in ids else []


class Deps:
    def __init__(self, pool):
        self.pool, self.music = pool, FakeCatalog()
        self.keys = type("K", (), {"box": BOX})()


async def linked_account(pool, active_at):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, comp, {"tz": "Asia/Singapore", "lang": "zh"})
    await S.link(pool, BOX, acc, platform="apple", user_token="tok", storefront="au")
    await pool.execute("UPDATE accounts SET last_active_at = $2 WHERE id = $1", acc, active_at)
    return acc


async def test_poll_saves_changes_only_throttled_and_skips_idle(pool):
    listen.reset()
    d = Deps(pool)
    acc = await linked_account(pool, NOW - timedelta(hours=1))
    idle = await linked_account(pool, NOW - timedelta(days=2))
    assert await listen.poll(d, NOW) == 1
    items = await context_line.load(pool, acc)
    assert items["music"][0] == {"song_id": "1", "name": "晴天", "artist": "周杰伦", "playing": False}   # 借了中文名
    assert "music" not in await context_line.load(pool, idle)
    assert await S.heard_keys(pool, acc)                                        # 记成听过，私选不推
    assert await listen.poll(d, NOW + timedelta(minutes=2)) == 0 and d.music.asked == 1   # 5 分钟一次
    assert await listen.poll(d, NOW + timedelta(minutes=6)) == 0                  # 同一首：不重存
    assert (await context_line.load(pool, acc))["music"][1] == NOW
    d.music.latest = s("2", "Always", "Daniel Caesar")
    assert await listen.poll(d, NOW + timedelta(minutes=12)) == 1
    assert (await context_line.load(pool, acc))["music"][0]["name"] == "Always"


async def test_phone_report_wins(pool):
    listen.reset()
    d = Deps(pool)
    acc = await linked_account(pool, NOW)
    await context_line.save(pool, acc, "music", {"song_id": "9", "name": "Blessed", "artist": "Daniel Caesar", "playing": True},
                            NOW - timedelta(minutes=5))
    assert await listen.poll(d, NOW) == 0
    assert (await context_line.load(pool, acc))["music"][0]["name"] == "Blessed"


async def test_no_key_no_poll(pool):
    listen.reset()
    d = Deps(pool)
    d.music = None
    await linked_account(pool, NOW)
    assert await listen.poll(d, NOW) == 0
