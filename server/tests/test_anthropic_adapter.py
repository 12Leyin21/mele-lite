from dataclasses import replace
import json

import anthropic
import httpx2
import pytest

from llm.anthropic_adapter import AnthropicAdapter
from llm.errors import LLMError
from llm.types import Block, ChatRequest, ImagePart, Msg, ToolCall, ToolRound, ToolSpec

TOOL = ToolSpec("memory_search", "翻记忆", {"type": "object", "properties": {"query": {"type": "string"}}})
REQ = ChatRequest(
    model="claude-sonnet-5",
    system=[Block("壹", cache=True), Block("贰", cache=True)],
    messages=[Msg("user", "早"), Msg("assistant", "早呀", cache=True), Msg("user", "会变区\n\n芒果能吃吗")],
    tools=[TOOL], thinking=True, user_tag="tag123",
)


class Blk:
    """冒充 SDK 的内容块。"""

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def model_dump(self, exclude_none=False):
        return {k: v for k, v in self.__dict__.items() if not (exclude_none and v is None)}


class FakeStream:
    def __init__(self, final):
        self.final = final

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def get_final_message(self):
        return self.final


class FakeMessages:
    def __init__(self, finals=(), errors=()):
        self.finals, self.errors, self.calls = list(finals), list(errors), []

    def stream(self, **kw):
        self.calls.append(kw)
        if self.errors:
            raise self.errors.pop(0)
        return FakeStream(self.finals.pop(0))


class FakeClient:
    def __init__(self, **kw):
        self.messages = FakeMessages(**kw)


def final(content, stop="end_turn", read=0, write=0, write_1h=None):
    split = None if write_1h is None else Blk(ephemeral_1h_input_tokens=write_1h,
                                              ephemeral_5m_input_tokens=write - write_1h)
    return Blk(content=content, stop_reason=stop, usage=Blk(
        input_tokens=50, output_tokens=7, cache_read_input_tokens=read, cache_creation_input_tokens=write,
        cache_creation=split))


def status_error(cls, status, msg):
    return cls(msg, response=httpx2.Response(status, request=httpx2.Request("POST", "https://api.test")),
               body=None)


def count_cache_marks(kw):
    return json.dumps(kw, ensure_ascii=False).count("cache_control")


def test_build_places_bookmarks_metadata_thinking():
    kw = AnthropicAdapter("k", client=FakeClient()).build(REQ)
    # 1 小时档（Tilia 09-28：隔 5 分钟以上回话不整段全价重写；不做保活）
    assert [b.get("cache_control") for b in kw["system"]] == [{"type": "ephemeral", "ttl": "1h"}] * 2
    assert kw["messages"][1]["content"][0]["cache_control"] == {"type": "ephemeral", "ttl": "1h"}
    assert "cache_control" in kw["messages"][1]["content"][0]            # 滚动书签在历史最后一条
    assert "cache_control" not in kw["messages"][2]["content"][0]        # 会变区那条不挂
    assert count_cache_marks(kw) == 3                                    # 最多 4 个，我们用 3 个
    assert kw["metadata"] == {"user_id": "tag123"}
    assert kw["thinking"] == {"type": "adaptive", "display": "summarized"}
    assert kw["tools"][0]["input_schema"]["properties"]["query"]["type"] == "string"


def test_no_thinking_param_for_model_without_thinking():
    req = ChatRequest(model="claude-haiku-4-5", system=[], messages=[Msg("user", "hi")], thinking=True)
    assert "thinking" not in AnthropicAdapter("k", client=FakeClient()).build(req)


def test_build_appends_tool_rounds():
    raw = [{"type": "tool_use", "id": "tu_1", "name": "memory_search", "input": {}}]
    req = ChatRequest(model="claude-sonnet-5", system=[], messages=[Msg("user", "hi")],
                      rounds=[ToolRound(raw, [ToolCall("tu_1", "memory_search", {})], ["没找到"])])
    msgs = AnthropicAdapter("k", client=FakeClient()).build(req)["messages"]
    assert msgs[-2] == {"role": "assistant", "content": raw}
    assert msgs[-1] == {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "tu_1", "content": "没找到"}]}


async def test_stream_parses_text_thinking_tools_usage():
    fc = FakeClient(finals=[final([
        Blk(type="thinking", thinking="她问芒果", signature="sig"),
        Blk(type="text", text="我翻翻"),
        Blk(type="tool_use", id="tu_1", name="memory_search", input={"query": "芒果"}),
    ], stop="tool_use", read=900, write=100)])
    r = await AnthropicAdapter("k", client=fc).stream(REQ)
    assert r.text == "我翻翻" and r.thinking == "她问芒果"
    assert r.tool_calls == [ToolCall("tu_1", "memory_search", {"query": "芒果"})]
    assert (r.usage.input, r.usage.cache_read, r.usage.cache_write, r.usage.output) == (50, 900, 100, 7)
    assert r.raw_assistant[0]["signature"] == "sig"      # 思考块原样留着，接着调要还回去


async def test_relay_rejecting_cache_control_falls_back_once():
    err = status_error(anthropic.BadRequestError, 400, "cache_control is not supported")
    fc = FakeClient(finals=[final([Blk(type="text", text="好")])], errors=[err])
    a = AnthropicAdapter("k", client=fc)
    r = await a.stream(REQ)
    assert r.text == "好" and a.cache_ok is False
    assert count_cache_marks(fc.messages.calls[1]) == 0


async def test_relay_rejecting_ttl_falls_back_to_five_minutes():
    err = status_error(anthropic.BadRequestError, 400, "cache_control.ttl: Extra inputs are not permitted")
    fc = FakeClient(finals=[final([Blk(type="text", text="好")])], errors=[err])
    a = AnthropicAdapter("k", client=fc)
    r = await a.stream(REQ)
    assert r.text == "好" and a.ttl_ok is False and a.cache_ok is True
    assert [b["cache_control"] for b in fc.messages.calls[1]["system"]] == [{"type": "ephemeral"}] * 2


async def test_usage_splits_one_hour_writes_and_prices_them_double():
    from llm.catalog import cost
    fc = FakeClient(finals=[final([Blk(type="text", text="好")], read=0, write=1000, write_1h=800)])
    r = await AnthropicAdapter("k", client=fc).stream(REQ)
    assert (r.usage.cache_write, r.usage.cache_write_1h) == (1000, 800)
    # sonnet-5：输入 2 美元 / 百万；5 分钟写 1.25 倍 = 2.5，1 小时写 2 倍 = 4
    want = (50 * 2.00 + 200 * 2.50 + 800 * 4.00 + 7 * 10.00) / 1_000_000
    assert abs(cost(r.usage, "claude-sonnet-5") - want) < 1e-12


@pytest.mark.parametrize("error,kind,retry", [
    (status_error(anthropic.AuthenticationError, 401, "bad key"), "auth", False),
    (status_error(anthropic.APIStatusError, 529, "overloaded"), "overloaded", True),
    (status_error(anthropic.BadRequestError, 400, "prompt too long"), "bad_request", False),
    (anthropic.APIConnectionError(request=httpx2.Request("POST", "https://api.test")), "network", True),
])
async def test_errors_are_classified(error, kind, retry):
    a = AnthropicAdapter("k", client=FakeClient(errors=[error]))
    with pytest.raises(LLMError) as ei:
        await a.stream(REQ)
    assert (ei.value.kind, ei.value.retryable) == (kind, retry)


def test_build_image_block_before_text():
    req = replace(REQ, messages=[Msg("user", "看", images=(ImagePart("image/jpeg", "QUJD"),))])
    content = AnthropicAdapter("k", client=FakeClient()).build(req)["messages"][-1]["content"]
    assert content[0] == {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "QUJD"}}
    assert content[1]["text"] == "看"
