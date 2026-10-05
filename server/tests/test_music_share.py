"""定哪一首（音乐第 2 步，移植自之前自用的 App relay/tests/test_music_share.py，Spotify 换成 Apple Music）+ 中文名（澳洲区只有英文）。"""
from music.apple import Song
from music.share import card_text, localize_lang, pick_share


def s(i, name, artist):
    return Song(i, name, artist, "", "", "", f"https://music.apple.com/au/song/{i}")


def test_named_artist_is_ready_unnamed_same_title_asks():
    r = pick_share("Always Daniel Caesar", [s("1", "Always", "Daniel Caesar"), s("2", "Always", "Bon Jovi")])
    assert r["status"] == "ready" and r["song"].id == "1"
    r = pick_share("Always", [s("1", "Always", "Daniel Caesar"), s("2", "Always", "Bon Jovi")])
    assert r["status"] == "needs_choice" and [c.id for c in r["candidates"]] == ["1", "2"]


def test_live_version_of_same_artist_is_not_ambiguous():
    r = pick_share("Best Part", [s("1", "Best Part (feat. H.E.R.)", "Daniel Caesar & H.E.R."),
                                 s("2", "Best Part - Live", "Daniel Caesar")])
    assert r["status"] == "ready" and r["song"].id == "1"


def test_not_found_and_unrelated_results():
    assert pick_share("xyz", [])["code"] == "NOT_FOUND"
    assert pick_share("zzqqxx不存在的歌", [s("1", "不存在 - band ver.", "163 braces")])["code"] == "NOT_FOUND"
    assert pick_share("zzqqxx", [s("1", "Zzyzx Rd Rain", "Visceral Rain")])["code"] == "NOT_FOUND"


def test_chinese_without_spaces_and_covers_rank_last():
    assert pick_share("晴天周杰伦", [s("1", "晴天", "周杰伦")])["status"] == "ready"
    r = pick_share("晴天 周杰伦", [s("9", "晴天 (鋼琴版) [原唱: 周杰倫]", "紀鈞瀚"), s("1", "晴天", "周杰伦")])
    assert r["status"] == "ready" and r["song"].id == "1"


def test_english_only_storefront_matches_through_chinese_names():
    """09-30 真试：澳洲区《晴天》叫 Sunny Day - Jay Chou。拿新加坡区的中文名一起比；卡上显示中文名。"""
    au = [s("1", "Sunny Day", "Jay Chou"), s("2", "Sunny Day (Live)", "Jay Chou")]
    zh = {"1": s("1", "晴天", "周杰伦"), "2": s("2", "晴天 (Live)", "周杰伦")}
    assert pick_share("晴天周杰伦", au)["code"] == "NOT_FOUND"                     # 不带中文名：对不上
    r = pick_share("晴天周杰伦", au, alt=zh)
    assert r["status"] == "ready" and r["song"].id == "1" and r["song"].url.endswith("/1")
    assert (r["display"].name, r["display"].artist) == ("晴天", "周杰伦")
    r = pick_share("Sunny Day Jay Chou", au, alt=zh)                               # 英文照样认
    assert r["status"] == "ready" and r["song"].id == "1"


def test_which_storefront_to_borrow_chinese_names_from():
    assert localize_lang("au", "zh") == ("sg", "zh-Hans-CN")
    assert localize_lang("us", "zh") == ("sg", "zh-Hans-CN")
    assert localize_lang("hk", "zh") is None and localize_lang("sg", "zh") is None     # 本来就有中文
    assert localize_lang("au", "en") is None


def test_card_text():
    assert card_text(s("1", "Always", "Daniel Caesar"), "这首是我们的") == "这首是我们的"
    assert card_text(s("1", "Always", "Daniel Caesar"), "") == "🎵 《Always》 — Daniel Caesar"
