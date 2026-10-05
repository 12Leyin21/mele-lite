"""塔罗牌义表 + 九个牌阵（10-03）：78 张中英齐全、牌阵张数和牌位对得上。"""
from brain import tarot_cards as TC
from brain import tarot_spreads as TS


def test_78_cards_unique_and_ordered():
    assert len(TC.CARDS) == 78 and len(set(TC.CARDS)) == 78
    assert TC.CARDS[0] == "major_00" and TC.CARDS[21] == "major_21"
    assert TC.CARDS[22] == "wands_01" and TC.CARDS[-1] == "pentacles_king"


def test_every_card_has_both_languages_and_orientations():
    for key in TC.CARDS:
        for lang in ("zh", "en"):
            c = TC.card(key, lang)
            assert c["key"] == key and c["name"]
            for side in ("upright", "reversed"):
                assert c[side]["core"], (key, lang, side)
                assert 3 <= len(c[side]["keywords"]) <= 4, (key, lang, side)
                if lang == "zh":
                    assert len(c[side]["core"]) <= 30, (key, side, c[side]["core"])


def test_entry_line():
    zh = TC.entry_line("major_00", True, "zh")
    assert zh.startswith("愚人（逆位）：") and "关键词：" in zh
    en = TC.entry_line("cups_02", False, "en")
    assert en.startswith("Two of Cups (upright): ") and "keywords: " in en


def test_spreads():
    counts = {"single": 1, "three": 3, "relationship": 7, "choice": 5, "diamond": 5, "moon": 4,
              "week": 7, "horseshoe": 7, "celtic": 10, "followup": 1}
    assert set(TS.SPREADS) == set(counts)
    for key, n in counts.items():
        s = TS.SPREADS[key]
        assert len(s.positions["zh"]) == len(s.positions["en"]) == len(s.layout) == n, key
        assert s.name["zh"] and s.name["en"] and s.usage["zh"] and s.usage["en"]
    pub = TS.public("zh")
    assert [p["key"] for p in pub][:2] == ["single", "three"] and "followup" not in [p["key"] for p in pub]
    assert pub[1]["positions"] == ["过去", "现在", "未来"] and pub[1]["layout"][0] == [0.22, 0.5]
