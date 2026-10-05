"""模型路由：按用户的钥匙挑接头，带重试地调模型。大脑只用 Route、make_adapter、call。"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Protocol

from .errors import LLMError
from .types import ChatRequest, Reply

PROVIDERS = ("anthropic", "deepseek", "openai", "openai-compatible", "gemini")
DEEPSEEK_URL = "https://api.deepseek.com"


@dataclass(frozen=True)
class Route:
    provider: str
    api_key: str
    chat_model: str
    ledger_model: str
    base_url: str | None = None
    age_model: str | None = None     # 压旧天用哪个；None = 跟写账本同一个
    trial: bool = False              # 这是我们的试用钥匙（每轮扣一次试用额度）


class Adapter(Protocol):
    async def stream(self, req: ChatRequest) -> Reply: ...


def make_adapter(route: Route) -> Adapter:
    """按供应商挑接头。接头按需才 import，没装某家的包也不影响别家。"""
    if route.provider == "anthropic":
        from .anthropic_adapter import AnthropicAdapter
        return AnthropicAdapter(route.api_key, base_url=route.base_url)
    if route.provider in ("deepseek", "openai", "openai-compatible"):
        from .openai_adapter import OpenAIAdapter
        base = route.base_url or (DEEPSEEK_URL if route.provider == "deepseek" else None)
        return OpenAIAdapter(route.api_key, base_url=base, flavor=route.provider)
    if route.provider == "gemini":
        from .gemini_adapter import GeminiAdapter
        return GeminiAdapter(route.api_key)
    raise ValueError(f"unknown provider {route.provider!r}")


async def call(adapter: Adapter, req: ChatRequest, *, retries: int = 2, base_delay: float = 1.0,
               sleep=asyncio.sleep) -> Reply:
    """调一次模型。网络抖、对方忙、限流：最多重试 retries 次，间隔翻倍；key 错、没余额这类不重试。"""
    attempt = 0
    while True:
        try:
            return await adapter.stream(req)
        except LLMError as e:
            if not e.retryable or attempt >= retries:
                raise
            await sleep(base_delay * (2 ** attempt))
            attempt += 1
