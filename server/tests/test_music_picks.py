"""每日私选的纯逻辑（音乐第 6 步），移植自之前自用的 App relay/tests/test_daily_picks.py，Spotify 换成 Apple Music。"""
import random

from music import picks as P


def item(i, name, artist, origin="new"):
    return {"id": i, "name": name, "artist": artist, "album": "", "artwork": "", "preview": "", "url": "", "origin": origin}


def test_seeds_weighted_blocked_and_votes_count():
    rng = random.Random(7)
    played = [("Daniel Caesar", 9), ("周杰伦", 1), ("Bad Guy", 5)]
    seeds = P.seed_artists(played, ["Frank Ocean"], {"bad guy": -3}, n=8, rng=rng)
    assert "Bad Guy" not in seeds and set(seeds) == {"Daniel Caesar", "周杰伦", "Frank Ocean"}
    assert P.seed_artists([], [], {"sza": 2, "nobody": -1}, rng=rng) == ["sza"]       # 没连也能靠「多来点」
    assert P.split_artists("Daniel Caesar & H.E.R.") == ["Daniel Caesar", "H.E.R."]
    assert P.split_artists("A, B & C") == ["A", "B", "C"]


def test_parse_artist_list():
    assert P.parse_artist_list('好的：["Giveon", "giveon", "Brent Faiyaz"] 希望喜欢') == ["Giveon", "Brent Faiyaz"]
    assert P.parse_artist_list("不知道") == []


def test_pool_filters_and_caps():
    rng = random.Random(7)
    heard = {P.song_key("Always", "Daniel Caesar")}
    cands = [item("a", "Always", "Daniel Caesar", "familiar"),
             item("b", "Get You", "Daniel Caesar", "familiar"),
             item("c", "Get You - Live", "Daniel Caesar", "familiar"),
             item("d", "Heartbreak Anniversary", "Giveon"),
             item("f", "晴天 (钢琴版)", "某人"),
             item("g", "Old Pick", "Giveon"),
             item("h", "Bad Song", "Bad Guy"),
             item("i", "One", "Brent Faiyaz"), item("j", "Two", "Brent Faiyaz"),
             item("k", "Three", "Brent Faiyaz"), item("l", "Four", "Brent Faiyaz")]
    pool = P.build_pool(cands, heard, {"g"}, {"bad guy": -3}, rng=rng)
    ids = {p["id"] for p in pool}
    assert {"b", "d"} <= ids and not ids & {"a", "c", "f", "g", "h"}
    assert len([p for p in pool if p["artist"] == "Brent Faiyaz"]) == 3
    assert P.by_artist(item("x", "t", "SZA & Frank Ocean"), "frank ocean")
    assert not P.by_artist(item("x", "t", "SZA Tribute Band"), "SZA")
    assert P.by_artist(item("x", "t", "Tyler, The Creator"), "Tyler, The Creator")
    assert P.by_artist(item("x", "t", "Tyler, The Creator & Kali Uchis"), "Tyler, The Creator")


def test_validate_picks():
    pool = [item(x, f"T{x}", "A") for x in "abcdef"]
    ok, err = P.validate_picks(pool, [{"id": "a", "why": "1"}, {"id": "b", "why": "2"}, {"id": "c", "why": "3"}])
    assert len(ok) == 3 and not err and ok[0]["why"] == "1"
    ok, err = P.validate_picks(pool, [{"id": "a", "why": "1"}, {"id": "zzz", "why": "编的"}, {"id": "c", "why": "3"}])
    assert not ok and "不在今天的候选池里" in err[0]
    ok, err = P.validate_picks(pool, [{"id": "a", "why": "1"}, {"id": "b", "why": ""}, {"id": "c", "why": "3"}])
    assert not ok and "没写为什么" in err[0]
    ok, err = P.validate_picks(pool, [{"id": "a", "why": "1"}])
    assert not ok and "要挑 3 首" in err[0]
    ok, err = P.validate_picks(pool, [{"id": "a", "why": "1"}], n=1)                   # 首数可调
    assert len(ok) == 1


def test_vote_weight():
    assert (P.vote_weight("up"), P.vote_weight("up", 5), P.vote_weight("down", 4), P.vote_weight("down", 5),
            P.vote_weight("meh", 5), P.vote_weight("")) == (1, 2, -1, -2, 0, 0)
    assert -2 > P.BLOCK_SCORE
