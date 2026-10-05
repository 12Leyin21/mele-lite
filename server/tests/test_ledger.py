from datetime import date, datetime, timedelta, timezone

from brain import ledger
from brain.archive import StoredMsg
from brain.ledger import (age_day, age_prompt, pieces, day_transcripts, defect, entry_budget, ground_text, join_text,
                          needs_roll, one_line, over_quota, pick_prompt, plan_roll, quota_for_age, render_ledger,
                          too_old, voice_samples, write_entry, write_prompt)
from llm.fake import FakeModel

NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)
D = date(2026, 9, 26)


def sm(i, role, text, minutes=0):
    return StoredMsg(i, role, text, "", NOW + timedelta(minutes=minutes))


def convo(n):
    return [sm(i, "user" if i % 2 else "assistant", f"第{i}条", i) for i in range(1, n + 1)]


MANGO = [sm(1, "user", "我对芒果过敏，吃了嘴唇会肿"), sm(2, "assistant", "记住了，以后不给你推荐芒果", 1)]


def test_needs_roll():
    assert needs_roll(60_000, 60_000) and not needs_roll(59_999, 60_000)


def test_plan_roll_keeps_count_and_starts_with_user():
    plan = plan_roll(convo(10), keep_count=4)
    assert [m.id for m in plan.kept] == [7, 8, 9, 10] and [m.id for m in plan.rolled] == [1, 2, 3, 4, 5, 6]
    plan = plan_roll(convo(10), keep_count=3)                   # 第 8 条是它说的，往后挪到用户那条
    assert [m.id for m in plan.kept] == [9, 10]


def test_plan_roll_keeps_chars():
    msgs = [sm(1, "user", "a" * 10), sm(2, "assistant", "b" * 10), sm(3, "user", "c" * 10),
            sm(4, "assistant", "d" * 10)]
    assert [m.id for m in plan_roll(msgs, keep_chars=35).kept] == [3, 4]
    assert [m.id for m in plan_roll(msgs, keep_chars=5).kept] == [3, 4]   # 至少留最后一来一回


def test_plan_roll_reads_module_constants(monkeypatch):
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    assert [m.id for m in plan_roll(convo(6)).kept] == [5, 6]


def test_voice_samples_last_six_of_its_own_lines():
    rolled = convo(20)
    assert voice_samples(rolled) == [f"第{i}条" for i in (10, 12, 14, 16, 18, 20)]


def test_quota_curve():
    assert [quota_for_age(a) for a in (0, 1, 2, 3, 13)] == [2500, 1000, 400, 100, 100]
    assert quota_for_age(1, "en") == 3000                                   # 英文 ×3


def test_entry_budget():
    assert entry_budget(10_000) == 500 and entry_budget(4000) == 200 and entry_budget(100) == 80
    assert entry_budget(100, "en") == 240


def test_over_quota_and_too_old():
    days = {D: "字" * 3000, D - timedelta(days=1): "字" * 1200, D - timedelta(days=2): "字" * 600,
            D - timedelta(days=5): "字" * 120, D - timedelta(days=14): "字" * 9000}
    assert over_quota(days, D, "zh") == [(D - timedelta(days=2), 2, 400)]  # 3000 < 2500×1.3；1200 < 1300；120 < 130
    days[D - timedelta(days=5)] = "字" * 131
    assert over_quota(days, D, "zh")[0] == (D - timedelta(days=5), 5, 100)
    assert too_old(days, D) == [D - timedelta(days=14)]


def test_join_and_one_line():
    assert join_text("聊了芒果", "定了周六见。", "zh") == "聊了芒果。定了周六见。"
    assert join_text("聊了芒果！", "定了周六见", "zh") == "聊了芒果！定了周六见"
    assert join_text("", "新的", "zh") == "新的"
    assert join_text("We talked.", "They left", "en") == "We talked. They left"
    assert one_line("9月26日：TA 说\n对芒果过敏。", "zh") == "TA 说对芒果过敏。"
    assert one_line("## 2026-09-26\nThey said\nhi", "en") == "They said hi"


def test_day_transcripts_split_by_local_day_and_chunk(monkeypatch):
    msgs = [sm(1, "user", "早"), sm(2, "assistant", "早呀", 1), sm(3, "user", "晚安", 60 * 5)]   # 20:00、20:01、次日 01:00（新加坡）
    out = day_transcripts(msgs, "Asia/Singapore", "zh")
    assert out == {D: ["[20:00] TA：早\n[20:01] 我：早呀"], D + timedelta(days=1): ["[01:00] TA：晚安"]}
    monkeypatch.setattr(ledger, "CHUNK_CHARS", 15)
    assert day_transcripts(msgs[:2], "Asia/Singapore", "zh")[D] == ["[20:00] TA：早", "[20:01] 我：早呀"]


SRC = "[20:00] TA：我对芒果过敏，吃了嘴唇会肿\n[20:01] 我：记住了，以后不给你推荐芒果"


def test_ground_text_drops_invented_sentences():
    assert ground_text("TA 说自己对芒果过敏。我答应以后不推荐芒果。TA 中了彩票。", SRC) == \
        "TA 说自己对芒果过敏。我答应以后不推荐芒果。"
    assert ground_text("TA 中了彩票。TA 去了火星。TA 对芒果过敏。", SRC) is None
    assert ground_text("TA 对芒果过敏 Lottery 1000000。", SRC) is None       # 原文里没有的英文名和数字


def test_ground_text_english_paraphrase_is_fine_names_are_not():
    src = "[20:00] Them: I'm allergic to mango, my lips swell\n[20:01] Me: Noted, no more mango suggestions"
    assert ground_text("They told me they're allergic to mango. I promised no more mango.", src) is not None
    assert ground_text("They are allergic to mango because Jake said so at 9:30.", src) is None


def test_defect():
    assert defect("短", 100, "Lumi") == "1 字，太短"
    assert "超过" in defect("字" * 101, 100, "Lumi")
    assert "第三人称" in defect("Lumi 说好。lumi 记住了。Lumi 答应了芒果的事。", 100, "Lumi")
    assert defect("我记住了 TA 对芒果过敏，以后不推荐。", 100, "Lumi") == ""


def test_write_prompt_mentions_tail_and_limit():
    p, limit = write_prompt(SRC, D, "", name="Lumi", lang="zh")
    assert limit == 80 and "9月26日" in p and "80 字以内" in p and "已有的账" in p and "最后一句" not in p
    p, _ = write_prompt(SRC, D, "早上聊了游泳。", name="Lumi", lang="zh")
    assert "最后一句是：「早上聊了游泳。」" in p and "不许出现「Lumi」" in p


def test_age_prompt_changes_with_age():
    recent = age_prompt("很长的记录", D, 1, 1000, name="Lumi", lang="zh")
    old = age_prompt("很长的记录", D, 5, 100, name="Lumi", lang="zh")
    assert "不是最终成品" in recent and "700～1000 字" in recent and "昨天" in recent and "情绪转折" in recent
    assert "主语 + 最终结果" in old and "70～100 字" in old and "5 天前" in old
    assert "Once more: 2100–3000" in age_prompt("x", D, 1, 3000, name="Lumi", lang="en")


async def test_write_entry_good_and_falls_back():
    f = FakeModel(["TA 说自己对芒果过敏，我答应以后不推荐芒果。"])
    text, spent = await write_entry(f, ["cheap", "main"], SRC, D, "", name="Lumi", lang="zh")
    assert text == "TA 说自己对芒果过敏，我答应以后不推荐芒果。" and [m for m, _ in spent] == ["cheap"]
    req = f.requests[0]
    assert req.thinking is False and req.tools == [] and "⟪对话开始⟫" in req.messages[0].text
    f = FakeModel(["TA：那我明天去买芒果吧\n我：好呀好呀我陪你去买", "TA 对芒果过敏，我记下了，以后不推荐。"])   # 续写 → 换下一条腿
    text, spent = await write_entry(f, ["cheap", "main"], SRC, D, "", name="Lumi", lang="zh")
    assert text == "TA 对芒果过敏，我记下了，以后不推荐。" and [m for m, _ in spent] == ["cheap", "main"]
    f = FakeModel(["Lumi 听 TA 说芒果过敏。Lumi 答应不推荐芒果。Lumi 记住了。"] * 2)                 # 第三人称，两条腿都打回
    assert (await write_entry(f, ["cheap", "cheap"], SRC, D, "", name="Lumi", lang="zh"))[0] is None


async def test_age_day_needs_it_shorter():
    old = "TA 说今天去游泳了，游了一千米，很累但是很开心。我夸 TA 坚持得好，TA 说下周还要去。" * 3
    f = FakeModel(["TA 去游泳了，游了一千米，很开心。"])
    short, _ = await age_day(f, ["haiku"], old, D, 5, 100, name="Lumi", lang="zh")
    assert short == "TA 去游泳了，游了一千米，很开心。"
    assert "二次压缩" in f.requests[0].messages[0].text
    copier = FakeModel([old[:199], old[:199]])                                # 没压到 2 倍配额以内 → 打回
    assert (await age_day(copier, ["haiku", "haiku"], old, D, 5, 100, name="Lumi", lang="zh"))[0] is None


def test_render_ledger():
    text = render_ledger({D: "- 聊了芒果"}, ["记住啦"], "zh")
    assert text == ("〔账本〕更早的对话，远的模糊、近的清楚（账里的「我」是你，「TA」是对方）：\n## 2026-09-26\n- 聊了芒果\n"
                    "〔腔调样本〕你之前的几句原话，照这个腔调接着说：\n- 「记住啦」")
    assert render_ledger({}, [], "zh") == ""


def test_pick_prompt_names_the_range():
    p = pick_prompt(MANGO, "zh")
    assert p.startswith("〔系统〕这不是用户在说话") and "我对芒果过敏" in p and "memory_remember" in p


def test_pieces_split_on_sentences():
    assert pieces("一二三。四五六。七八九。", 7) == ["一二三。", "四五六。", "七八九。"]
    assert pieces("一二三。四五六。七八九。", 8) == ["一二三。四五六。", "七八九。"]
    assert pieces("We swam. They left early.", 12) == ["We swam.", "They left early."]


async def test_age_day_in_pieces_for_deepseek():
    old = "TA 去游泳了，游了一千米，很累但是很开心，我夸 TA 坚持得好。" * 40                 # 约 1300 字 → 切 3 块
    f = FakeModel(["TA 去游泳了，游了一千米。"] * 2 + ["TA 去游泳了，游了一千米，很累。" * 100])   # 第三块两条腿都超长
    f.script.append("TA 去游泳了，游了一千米，很累。" * 100)
    short, spent = await age_day(f, ["deepseek-flash", "deepseek-flash"], old, D, 1, 1000, name="Lumi", lang="zh")
    n = len(pieces(old, 600))
    assert n == 3 and len(f.requests) == 4 and len(spent) == 4
    assert short.startswith("TA 去游泳了，游了一千米。TA 去游泳了，游了一千米。")          # 压不动的那块原样留着
    assert "（昨天）" in f.requests[0].messages[0].text and "～" in f.requests[0].messages[0].text


def test_user_name_replaces_ta_everywhere():
    msgs = [sm(1, "user", "早"), sm(2, "assistant", "早呀", 1)]
    assert day_transcripts(msgs, "UTC", "zh", "小满")[D] == ["[12:00] 小满：早\n[12:01] 我：早呀"]
    p, _ = write_prompt(SRC, D, "", name="Lumi", lang="zh", user_name="小满")
    assert "Lumi和小满的一段对话" in p and "对方写「小满」" in p and "「小满：」是对方" in p and "TA" not in p.split("⟪对话开始⟫")[0]
    a = age_prompt("x", D, 5, 100, name="Lumi", lang="zh", user_name="小满")
    assert "「小满没吃晚饭」" in a and "「小满夸我」" in a and "TA" not in a
    e = age_prompt("x", D, 1, 3000, name="Lumi", lang="en", user_name="Mia")
    assert '"Mia" is the other person' in e and "I praised Mia" in e and "they skipped" not in e and "Mia skipped" in e
    e = age_prompt("x", D, 5, 300, name="Lumi", lang="en")
    assert '→ "They skipped dinner"' in e and "I praised them" in e
    assert render_ledger({D: "聊了芒果"}, [], "zh", "小满").startswith("〔账本〕更早的对话，远的模糊、近的清楚（账里的「我」是你，「小满」是对方）")


async def test_new_name_on_old_ta_ledger_is_not_invention():
    old = "TA 说今天去游泳了，游了一千米，很累但是很开心。" * 4
    f = FakeModel(["Mia 去游泳了，游了一千米，很开心。"])
    short, _ = await age_day(f, ["haiku"], old, D, 5, 100, name="Lumi", lang="zh", user_name="Mia")
    assert short == "Mia 去游泳了，游了一千米，很开心。"
