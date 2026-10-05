from memory import words


def test_mixed_chinese_english_tokens():
    t = words.tokens("我今天去 Fremantle 吃了牛肉面")
    assert "fremantle" in t
    assert "牛肉面" in t or "牛肉" in t
    assert "我" not in t and "了" not in t      # 停用词去掉


def test_single_latin_letters_dropped_but_single_cjk_kept():
    t = words.tokens("a 猫 b")
    assert "a" not in t and "b" not in t
    assert "猫" in t


def test_tokens_are_safe_for_tsquery():
    q = words.tsquery("芒果 & 过敏 | (drop) ! 'x'")
    for part in q.split(" | "):
        assert part.replace(" ", "").isalnum()


def test_tsquery_dedupes_and_empty_when_nothing():
    assert words.tsquery("芒果 芒果") == "芒果"
    assert words.tsquery("的 了 吗") == ""


def test_cjk_bigrams():
    assert words.cjk_bigrams("芒果过敏 ok") == ["芒果", "果过", "过敏"]
