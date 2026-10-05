from brain import manuals


def test_handbook_has_index_then_always_manuals():
    text = manuals.render_handbook("zh")
    assert text.startswith("# 说明书")                  # 不带名字：别的联系人、导入的角色也看这一份（10-01）
    for name in ("memory", "people", "sticky"):
        assert f"## 手册 · {name}" in text
    assert "<!--" not in text                       # 标记行不给模型看


def test_every_manual_is_listed_and_languages_match():
    for lang in ("zh", "en"):
        index, ms = manuals.load(lang)
        for m in ms:
            assert f"| {m.name} |" in index, (lang, m.name)
    zh = {(m.name, m.mode) for m in manuals.load("zh")[1]}
    en = {(m.name, m.mode) for m in manuals.load("en")[1]}
    assert zh == en


def test_on_demand_manuals_stay_out_of_the_handbook(tmp_path, monkeypatch):
    (tmp_path / "zh").mkdir()
    (tmp_path / "zh" / "lumi.md").write_text("# 目录\n| tarot | 现翻 | 抽牌 |", encoding="utf-8")
    (tmp_path / "zh" / "memory.md").write_text("<!-- mode: always -->\n记忆全文", encoding="utf-8")
    (tmp_path / "zh" / "tarot.md").write_text("<!-- mode: on-demand -->\n塔罗全文", encoding="utf-8")
    monkeypatch.setattr(manuals, "ROOT", tmp_path)
    manuals.load.cache_clear()
    try:
        text = manuals.render_handbook("zh")
        assert "记忆全文" in text and "塔罗全文" not in text
        assert manuals.read_manual("tarot", "zh") == "塔罗全文"
        assert manuals.read_manual("Tarot.md", "zh") == "塔罗全文"
        assert manuals.read_manual("nope", "zh") is None
        assert manuals.manual_names("zh") == ["memory", "tarot"]
    finally:
        manuals.load.cache_clear()


def test_long_mode_drops_the_talk_section_only():
    for lang, head, nxt in (("zh", "## 说话", "## 手册目录"), ("en", "## How you talk", "## Manuals")):
        full, long_ = manuals.render_handbook(lang), manuals.render_handbook(lang, chat_rules=False)
        assert head in full and head not in long_
        assert nxt in long_ and "## 手册 · memory" in manuals.render_handbook("zh", chat_rules=False)
