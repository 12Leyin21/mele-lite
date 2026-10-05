"""音乐第 3 步：连接（用户凭证加密存）、歌单、私选、投票（照之前自用的 App vote_weight）、听过的、导出 / 删号。测试用小满 / Mia。"""
from datetime import date

from cryptography.fernet import Fernet

from brain import accounts, auth
from music import store as S
from music.apple import Song

BOX = auth.KeyBox(Fernet.generate_key())
DAY = date(2026, 10, 1)


def song(i, name="Always", artist="Daniel Caesar"):
    return Song(i, name, artist, "Freudian", f"https://art/{i}.jpg", f"https://p/{i}.m4a", f"https://music.apple.com/au/song/{i}")


async def test_link_keeps_token_encrypted_and_out_of_export(pool):
    acc = await accounts.create_account(pool)
    assert await S.get_link(pool, BOX, acc) is None
    await S.link(pool, BOX, acc, platform="apple", user_token="USER-TOKEN-秘密", storefront="au")
    raw = await pool.fetchval("SELECT user_token FROM music_links WHERE account_id = $1", acc)
    assert b"USER-TOKEN" not in bytes(raw)
    got = await S.get_link(pool, BOX, acc)
    assert (got.platform, got.user_token, got.storefront) == ("apple", "USER-TOKEN-秘密", "au")
    await S.link(pool, BOX, acc, platform="netease")                       # 换平台：凭证清掉
    got = await S.get_link(pool, BOX, acc)
    assert (got.platform, got.user_token) == ("netease", None)
    exported = str(await accounts.export_account(pool, acc))
    assert "USER-TOKEN" not in exported and "netease" in exported
    await S.unlink(pool, acc)
    assert await S.get_link(pool, BOX, acc) is None


async def test_shelf_dedupes_and_isolates(pool):
    a, b = await accounts.create_account(pool), await accounts.create_account(pool)
    await S.shelve(pool, a, song("1"), source="share", why="这首是我们的")
    await S.shelve(pool, a, song("1"), source="pick", why="")                # 同一首不收两遍
    await S.shelve(pool, a, song("2", "Blessed"), source="pick", why="雨天")
    assert [(x["name"], x["why"]) for x in await S.shelf(pool, a)] == [("Blessed", "雨天"), ("Always", "这首是我们的")]
    assert await S.shelf(pool, b) == []


async def test_picks_and_votes_move_artist_scores(pool):
    acc = await accounts.create_account(pool)
    await S.save_picks(pool, acc, DAY, [(song("1", "Good Days", "SZA"), "像周日早上"),
                                        (song("2", "Ivy", "Frank Ocean & SZA"), "慢一点的")])
    ps = await S.picks_on(pool, acc, DAY)
    assert [(p["pos"], p["name"], p["why"], p["vote"]) for p in ps] == [(0, "Good Days", "像周日早上", ""), (1, "Ivy", "慢一点的", "")]
    await S.vote(pool, acc, DAY, 0, "up", stars=5, reason="好听")
    assert await S.artist_scores(pool, acc) == {"sza": 2}                   # 5 星加倍
    await S.vote(pool, acc, DAY, 0, "up", stars=3)                          # 改星：按差算，不刷分
    assert await S.artist_scores(pool, acc) == {"sza": 1}
    await S.vote(pool, acc, DAY, 1, "down", stars=5)
    assert await S.artist_scores(pool, acc) == {"sza": -1, "frank ocean": -2}   # 一首歌最多 -2，拉黑不了
    await S.vote(pool, acc, DAY, 1, "meh")
    assert await S.artist_scores(pool, acc) == {"sza": 1}                   # 无感不加不扣；归零的删掉
    p = (await S.picks_on(pool, acc, DAY))[0]
    assert (p["vote"], p["stars"], p["reason"]) == ("up", 3, "好听")
    assert await S.vote(pool, acc, DAY, 9, "up") is None


async def test_heard_and_delete_account(pool):
    acc = await accounts.create_account(pool)
    await S.note_heard(pool, acc, ["k1", "k2"])
    await S.note_heard(pool, acc, ["k2"])
    assert await S.heard_keys(pool, acc) == {"k1", "k2"}
    await S.shelve(pool, acc, song("1"), source="share", why="")
    await accounts.delete_account(pool, acc)
    assert await pool.fetchval("SELECT count(*) FROM music_shelf") == 0
    assert await pool.fetchval("SELECT count(*) FROM music_heard") == 0
