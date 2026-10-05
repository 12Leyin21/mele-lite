import pytest

from llm.cachecheck import cache_check
from llm.errors import LLMError
from llm.fake import FakeModel
from llm.keys import FileKeys
from llm.router import Route, call, make_adapter
from llm.types import Block, ChatRequest, Msg, Usage

REQ = ChatRequest(model="m", system=[Block("sys", cache=True)], messages=[Msg("user", "hi")])


async def _nosleep(_):
    return None


async def test_fake_model_scripts_and_records():
    f = FakeModel(["你好", {"text": "", "calls": [("memory_search", {"query": "芒果"})]}])
    r1 = await f.stream(REQ)
    r2 = await f.stream(REQ)
    assert r1.text == "你好" and r1.tool_calls == []
    assert r2.tool_calls[0].name == "memory_search" and r2.tool_calls[0].args == {"query": "芒果"}
    assert len(f.requests) == 2


async def test_call_retries_retryable_then_succeeds():
    f = FakeModel([LLMError("rate", retryable=True), LLMError("overloaded", retryable=True), "ok"])
    slept = []

    async def sleep(s):
        slept.append(s)

    r = await call(f, REQ, sleep=sleep)
    assert r.text == "ok" and slept == [1.0, 2.0]


async def test_call_does_not_retry_auth():
    f = FakeModel([LLMError("auth"), "never"])
    with pytest.raises(LLMError) as ei:
        await call(f, REQ, sleep=_nosleep)
    assert ei.value.kind == "auth" and len(f.requests) == 1


async def test_call_gives_up_after_retries():
    f = FakeModel([LLMError("rate", retryable=True)] * 3)
    with pytest.raises(LLMError):
        await call(f, REQ, retries=2, sleep=_nosleep)
    assert len(f.requests) == 3


def test_file_keys_defaults_ledger_model_from_catalog(tmp_path):
    p = tmp_path / "keys.toml"
    p.write_text('[default]\nprovider = "deepseek"\napi_key = "sk-test"\nchat_model = "deepseek-v4-pro"\n',
                 encoding="utf-8")
    assert FileKeys(p).route_for(None) == Route(
        provider="deepseek", api_key="sk-test", chat_model="deepseek-v4-pro", ledger_model="deepseek-flash",
        age_model="deepseek-flash")


def test_file_keys_custom_model_ledger_is_itself(tmp_path):
    p = tmp_path / "keys.toml"
    p.write_text('[default]\nprovider = "openai-compatible"\napi_key = "k"\nchat_model = "my-model"\n'
                 'base_url = "https://relay.example/v1"\n', encoding="utf-8")
    r = FileKeys(p).route_for(None)
    assert r.ledger_model == "my-model" and r.base_url == "https://relay.example/v1"


def test_file_keys_rejects_unknown_provider(tmp_path):
    p = tmp_path / "keys.toml"
    p.write_text('[default]\nprovider = "nope"\napi_key = "k"\nchat_model = "m"\n', encoding="utf-8")
    with pytest.raises(ValueError):
        FileKeys(p)


def test_make_adapter_rejects_unknown_provider():
    with pytest.raises(ValueError):
        make_adapter(Route(provider="nope", api_key="k", chat_model="m", ledger_model="m"))


async def test_cache_check_hit():
    f = FakeModel([{"text": "好", "usage": Usage(input=2000)},
                   {"text": "好", "usage": Usage(input=10, cache_read=1990)}])
    assert (await cache_check(f, "m", "sys", []))["result"] == "hit"


async def test_cache_check_miss():
    f = FakeModel([{"text": "好", "usage": Usage(input=2000)}, {"text": "好", "usage": Usage(input=2000)}])
    assert (await cache_check(f, "m", "sys", []))["result"] == "miss"


async def test_cache_check_unknown_when_not_reported():
    u = Usage(input=2000, cache_known=False)
    f = FakeModel([{"text": "好", "usage": u}, {"text": "好", "usage": u}])
    assert (await cache_check(f, "m", "sys", []))["result"] == "unknown"


async def test_cache_check_unknown_when_request_failed():
    f = FakeModel([LLMError("auth")])
    res = await cache_check(f, "m", "sys", [])
    assert res["result"] == "unknown" and "auth" in res["reason"]
