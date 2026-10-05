from dataclasses import replace
from types import SimpleNamespace

import httpx2
import openai
import pytest
from openai.types.chat import ChatCompletionChunk

from llm.errors import LLMError
from llm.openai_adapter import OpenAIAdapter
from llm.types import Block, ChatRequest, ImagePart, Msg, ToolCall, ToolRound, ToolSpec

TOOL = ToolSpec("memory_search", "翻记忆", {"type": "object", "properties": {"query": {"type": "string"}}})
REQ = ChatRequest(
    model="deepseek-flash",
    system=[Block("稳定", cache=True), Block("账本", cache=True)],
    messages=[Msg("user", "早"), Msg("assistant", "早呀", cache=True), Msg("user", "〔现在〕…\n\n芒果能吃吗")],
    tools=[TOOL], thinking=True, user_tag="tag123",
)


def chunk(delta=None, finish=None, usage=None):
    d = {"id": "c", "object": "chat.completion.chunk", "created": 0, "model": "m",
         "choices": [] if delta is None and finish is None
         else [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
    if usage:
        d["usage"] = usage
    return ChatCompletionChunk.model_validate(d)


class FakeCompletions:
    def __init__(self, chunks=(), error=None):
        self.chunks, self.error, self.kw = list(chunks), error, None

    async def create(self, **kw):
        self.kw = kw
        if self.error:
            raise self.error

        async def gen():
            for c in self.chunks:
                yield c
        return gen()


def fake_client(**kw):
    return SimpleNamespace(chat=SimpleNamespace(completions=FakeCompletions(**kw)))


def status_error(cls, status, msg):
    return cls(msg, response=httpx2.Response(status, request=httpx2.Request("POST", "https://api.test")),
               body=None)


def test_build_deepseek():
    kw = OpenAIAdapter("k", flavor="deepseek", client=fake_client()).build(REQ)
    assert kw["messages"][0] == {"role": "system", "content": "稳定\n\n账本"}
    assert [m["role"] for m in kw["messages"]] == ["system", "user", "assistant", "user"]
    assert kw["extra_body"] == {"thinking": {"type": "enabled"}}
    assert kw["tools"][0]["function"]["name"] == "memory_search"
    assert kw["max_tokens"] == 8000 and "prompt_cache_key" not in kw
    assert kw["stream"] is True and kw["stream_options"] == {"include_usage": True}


def test_build_openai_uses_cache_key_and_completion_tokens():
    kw = OpenAIAdapter("k", flavor="openai", client=fake_client()).build(REQ)
    assert kw["prompt_cache_key"] == "tag123"
    assert kw["max_completion_tokens"] == 8000 and "max_tokens" not in kw
    assert "extra_body" not in kw


def test_build_appends_tool_rounds():
    raw = {"role": "assistant", "content": None, "tool_calls": [
        {"id": "call_a", "type": "function", "function": {"name": "memory_search", "arguments": "{}"}}]}
    req = ChatRequest(model="m", system=[], messages=[Msg("user", "hi")],
                      rounds=[ToolRound(raw, [ToolCall("call_a", "memory_search", {})], ["没找到"])])
    msgs = OpenAIAdapter("k", client=fake_client()).build(req)["messages"]
    assert msgs[-2] == raw
    assert msgs[-1] == {"role": "tool", "tool_call_id": "call_a", "content": "没找到"}


async def test_deepseek_text_reasoning_usage():
    fc = fake_client(chunks=[
        chunk({"role": "assistant", "reasoning_content": "想一想"}),
        chunk({"content": "你好"}),
        chunk({"content": "呀"}, finish="stop"),
        chunk(usage={"prompt_tokens": 1000, "completion_tokens": 20, "total_tokens": 1020,
                     "prompt_cache_hit_tokens": 900, "prompt_cache_miss_tokens": 100}),
    ])
    r = await OpenAIAdapter("k", flavor="deepseek", client=fc).stream(REQ)
    assert r.text == "你好呀" and r.thinking == "想一想" and r.tool_calls == []
    assert (r.usage.input, r.usage.cache_read, r.usage.output, r.usage.cache_known) == (100, 900, 20, True)
    assert r.stop == "stop"


async def test_tool_call_fragments_are_assembled():
    fc = fake_client(chunks=[
        chunk({"reasoning_content": "该翻记忆"}),
        chunk({"tool_calls": [{"index": 0, "id": "call_a", "type": "function",
                               "function": {"name": "memory_search", "arguments": ""}}]}),
        chunk({"tool_calls": [{"index": 0, "function": {"arguments": "{\"query\": \"芒"}}]}),
        chunk({"tool_calls": [{"index": 0, "function": {"arguments": "果\"}"}}]}, finish="tool_calls"),
    ])
    r = await OpenAIAdapter("k", flavor="deepseek", client=fc).stream(REQ)
    assert r.tool_calls == [ToolCall("call_a", "memory_search", {"query": "芒果"})]
    assert r.raw_assistant["tool_calls"][0]["function"]["arguments"] == '{"query": "芒果"}'
    assert r.raw_assistant["reasoning_content"] == "该翻记忆"   # DeepSeek 思考模式下接着调要还回去


async def test_openai_cached_tokens_and_missing_cache_field():
    fc = fake_client(chunks=[chunk({"content": "hi"}, finish="stop"), chunk(usage={
        "prompt_tokens": 500, "completion_tokens": 5, "total_tokens": 505,
        "prompt_tokens_details": {"cached_tokens": 300}})])
    r = await OpenAIAdapter("k", flavor="openai", client=fc).stream(REQ)
    assert (r.usage.input, r.usage.cache_read, r.usage.cache_known) == (200, 300, True)

    fc2 = fake_client(chunks=[chunk({"content": "hi"}, finish="stop"), chunk(usage={
        "prompt_tokens": 500, "completion_tokens": 5, "total_tokens": 505})])
    r2 = await OpenAIAdapter("k", flavor="openai-compatible", client=fc2).stream(REQ)
    assert (r2.usage.input, r2.usage.cache_read, r2.usage.cache_known) == (500, 0, False)


@pytest.mark.parametrize("error,kind,retry", [
    (status_error(openai.RateLimitError, 429, "slow down"), "rate", True),
    (status_error(openai.APIStatusError, 402, "Insufficient Balance"), "balance", False),
    (status_error(openai.AuthenticationError, 401, "bad key"), "auth", False),
    (openai.APIConnectionError(request=httpx2.Request("POST", "https://api.test")), "network", True),
])
async def test_errors_are_classified(error, kind, retry):
    a = OpenAIAdapter("k", flavor="deepseek", client=fake_client(error=error))
    with pytest.raises(LLMError) as ei:
        await a.stream(REQ)
    assert (ei.value.kind, ei.value.retryable) == (kind, retry)


def test_build_image_parts():
    req = replace(REQ, messages=[Msg("user", "看", images=(ImagePart("image/jpeg", "QUJD"),))])
    kw = OpenAIAdapter("k", flavor="openai", client=fake_client()).build(req)
    assert kw["messages"][-1]["content"] == [{"type": "text", "text": "看"},
                                             {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}}]
