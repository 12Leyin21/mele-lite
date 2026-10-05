from datetime import datetime, timezone
from uuid import uuid4

from brain.context import ContextParts, build_request, render_volatile, user_tag
from llm.anthropic_adapter import AnthropicAdapter
from llm.types import Msg, ToolSpec
from memory.models import Memory, RecallLine, RecallResult

TOOLS = [ToolSpec("a", "x", {"type": "object"})]
NOW = datetime(2026, 9, 26, 13, 5, tzinfo=timezone.utc)


def parts(history, volatile="〔现在〕…", text="在吗", ledger="〔账本〕…"):
    return ContextParts(tools=TOOLS, base="壹", ledger=ledger, history=history, volatile=volatile, user_text=text)


def mem(i, content, **kw):
    base = dict(id=i, user_id=uuid4(), kind="memory", content=content, importance=5, valence=0, arousal=0,
                tags=[], resolved=False, created_at=NOW, updated_at=NOW, last_recalled_at=None, recall_count=0)
    base.update(kw)
    return Memory(**base)


def test_order_and_bookmarks():
    req = build_request(parts([Msg("user", "早"), Msg("assistant", "早呀")]), model="m", thinking=True, user_tag="t")
    assert [b.text for b in req.system] == ["壹", "〔账本〕…"] and all(b.cache for b in req.system)
    assert [m.cache for m in req.messages] == [False, True, False]
    assert req.messages[-1] == Msg("user", "〔现在〕…\n\n在吗")
    assert req.tools == TOOLS and req.user_tag == "t" and req.thinking and req.model == "m"


def test_no_ledger_no_history():
    req = build_request(parts([], ledger=""), model="m", thinking=False, user_tag="t")
    assert len(req.system) == 1 and req.messages == [Msg("user", "〔现在〕…\n\n在吗")]


def test_history_starting_with_assistant_gets_a_lead_in():
    req = build_request(parts([Msg("assistant", "上次聊到这")]), model="m", thinking=False, user_tag="t")
    assert req.messages[0] == Msg("user", "（更早的对话在账本里）")


def test_user_tag_stable_and_opaque():
    u = uuid4()
    assert user_tag(u) == user_tag(u) and str(u) not in user_tag(u) and len(user_tag(u)) == 32


def test_render_volatile_full():
    person = mem(9, "生日 3 月 14 日", kind="person", name="秀兰", relation="妈妈")
    r = RecallResult(full=[mem(1, "小满对芒果过敏")], lines=[RecallLine(2, "周二游泳…")], people=[person])
    v = render_volatile(now=NOW, tz="Asia/Singapore", lang="zh", recall=r, sticky="明早问面试",
                        lines=["〔先想再说〕…"])
    assert v.splitlines() == [
        "〔以下是 app 附上的参考，不是对方说的话〕",
        "〔现在〕2026-09-26 21:05 周六（Asia/Singapore）",
        "〔记忆浮上来〕", "- 小满对芒果过敏", "- 周二游泳…",
        "〔人物卡 · 秀兰〕是谁：妈妈｜要记得：生日 3 月 14 日",
        "〔便利贴〕明早问面试",
        "〔先想再说〕…",
    ]


def test_render_volatile_minimal_english():
    v = render_volatile(now=NOW, tz="UTC", lang="en", recall=None, sticky="", lines=[])
    assert v.splitlines() == ["〔Notes attached by the app — not the user's words〕",
                              "〔Now〕2026-09-26 13:05 Sat (UTC)"]


def _strip_cache(obj):
    if isinstance(obj, dict):
        return {k: _strip_cache(v) for k, v in obj.items() if k != "cache_control"}
    if isinstance(obj, list):
        return [_strip_cache(v) for v in obj]
    return obj


def test_prefix_is_byte_stable_across_turns():
    """连聊三轮：上一轮的「工具 + system + 历史」逐字节原样出现在下一轮开头（书签位置可以挪）。
    这是缓存命中率的命根子。"""
    a = AnthropicAdapter("k", client=object())
    history: list[Msg] = []
    prev = None
    for turn in range(3):
        req = build_request(parts(list(history), volatile=f"〔现在〕第{turn}轮", text=f"第{turn}句"),
                            model="claude-sonnet-5", thinking=False, user_tag="t")
        kw = _strip_cache(a.build(req))
        if prev is not None:
            assert kw["tools"] == prev["tools"] and kw["system"] == prev["system"]
            n = len(prev["messages"]) - 1          # 上一轮除了最后那条（会变区 + 那句话）
            assert kw["messages"][:n] == prev["messages"][:n]
            assert kw["messages"][n]["content"][0]["text"] == f"第{turn - 1}句"   # 进历史的只有原话
        history += [Msg("user", f"第{turn}句"), Msg("assistant", f"回{turn}")]
        prev = kw


def test_render_volatile_puts_about_them_in_its_own_section():
    r = RecallResult(full=[mem(1, "下周二考 OSCE"), mem(2, "燕麦拿铁要半糖", kind="about")],
                     lines=[RecallLine(3, "周末爱去海边…", kind="about")], people=[])
    v = render_volatile(now=NOW, tz="UTC", lang="zh", recall=r, sticky="", lines=[])
    assert v.splitlines()[2:] == ["〔记忆浮上来〕", "- 下周二考 OSCE", "〔关于 TA〕", "- 燕麦拿铁要半糖", "- 周末爱去海边…"]
