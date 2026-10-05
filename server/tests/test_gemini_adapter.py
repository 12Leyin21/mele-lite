from dataclasses import replace
from types import SimpleNamespace

import pytest
from google.genai import errors as gerrors
from google.genai import types

from llm.anthropic_adapter import AnthropicAdapter
from llm.errors import LLMError
from llm.gemini_adapter import GeminiAdapter
from llm.openai_adapter import OpenAIAdapter
from llm.router import Route, make_adapter
from llm.types import Block, ChatRequest, ImagePart, Msg, ToolCall, ToolRound, ToolSpec

TOOL = ToolSpec("memory_search", "翻记忆", {"type": "object", "properties": {"query": {"type": "string"}}})
REQ = ChatRequest(model="gemini-x", system=[Block("壹"), Block("贰")],
                  messages=[Msg("user", "早"), Msg("assistant", "早呀"), Msg("user", "芒果能吃吗")],
                  tools=[TOOL], thinking=True)


class FakeModels:
    def __init__(self, chunks=(), error=None):
        self.chunks, self.error, self.kw = list(chunks), error, None

    async def generate_content_stream(self, **kw):
        self.kw = kw
        if self.error:
            raise self.error

        async def gen():
            for c in self.chunks:
                yield c
        return gen()


def fake_client(**kw):
    return SimpleNamespace(aio=SimpleNamespace(models=FakeModels(**kw)))


def resp(parts, usage=None, finish=None):
    return types.GenerateContentResponse(
        candidates=[types.Candidate(content=types.Content(role="model", parts=parts), finish_reason=finish)],
        usage_metadata=usage)


def test_build_roles_system_tools_thinking():
    contents, cfg = GeminiAdapter("k", client=fake_client()).build(REQ)
    assert [c.role for c in contents] == ["user", "model", "user"]
    assert cfg.system_instruction == "壹\n\n贰"
    assert cfg.tools[0].function_declarations[0].name == "memory_search"
    assert cfg.automatic_function_calling.disable is True
    assert cfg.thinking_config.include_thoughts is True


def test_build_appends_tool_rounds():
    raw = types.Content(role="model", parts=[types.Part(function_call=types.FunctionCall(name="memory_search", args={}))])
    req = ChatRequest(model="g", system=[], messages=[Msg("user", "hi")],
                      rounds=[ToolRound(raw, [ToolCall("c0", "memory_search", {})], ["没找到"])])
    contents, _ = GeminiAdapter("k", client=fake_client()).build(req)
    assert contents[-2] is raw
    fr = contents[-1].parts[0].function_response
    assert fr.name == "memory_search" and fr.response == {"result": "没找到"}


async def test_stream_text_thoughts_calls_usage():
    fc = fake_client(chunks=[
        resp([types.Part(text="她问芒果", thought=True)]),
        resp([types.Part(text="我翻翻")]),
        resp([types.Part(function_call=types.FunctionCall(name="memory_search", args={"query": "芒果"}))],
             usage=types.GenerateContentResponseUsageMetadata(
                 prompt_token_count=100, cached_content_token_count=60, candidates_token_count=5,
                 thoughts_token_count=3), finish="STOP"),
    ])
    r = await GeminiAdapter("k", client=fc).stream(REQ)
    assert r.text == "我翻翻" and r.thinking == "她问芒果"
    assert r.tool_calls == [ToolCall("call_0", "memory_search", {"query": "芒果"})]
    assert (r.usage.input, r.usage.cache_read, r.usage.output) == (40, 60, 8)
    assert r.stop == "STOP" and r.raw_assistant.role == "model" and len(r.raw_assistant.parts) == 3


@pytest.mark.parametrize("code,kind", [(429, "rate"), (401, "auth"), (500, "overloaded")])
async def test_errors_are_classified(code, kind):
    err = (gerrors.ClientError if code < 500 else gerrors.ServerError)(code, {"error": {"message": "x"}})
    with pytest.raises(LLMError) as ei:
        await GeminiAdapter("k", client=fake_client(error=err)).stream(REQ)
    assert ei.value.kind == kind


def test_make_adapter_picks_by_provider():
    a = make_adapter(Route("deepseek", "k", "deepseek-flash", "deepseek-flash"))
    assert isinstance(a, OpenAIAdapter) and a.flavor == "deepseek"
    assert "api.deepseek.com" in str(a.client.base_url)
    assert isinstance(make_adapter(Route("anthropic", "k", "claude-sonnet-5", "claude-haiku-4-5")),
                      AnthropicAdapter)
    assert isinstance(make_adapter(Route("gemini", "k", "g", "g")), GeminiAdapter)
    relay = make_adapter(Route("openai-compatible", "k", "m", "m", base_url="https://relay.example/v1"))
    assert "relay.example" in str(relay.client.base_url)


def test_build_image_part():
    req = replace(REQ, messages=[Msg("user", "看", images=(ImagePart("image/jpeg", "QUJD"),))])
    contents, _ = GeminiAdapter("k", client=fake_client()).build(req)
    parts = contents[-1].parts
    assert parts[0].inline_data.data == b"ABC" and parts[0].inline_data.mime_type == "image/jpeg" and parts[1].text == "看"
