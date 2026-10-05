"""模型调用出错时统一成一种错误。大脑按 kind 决定怎么跟用户说；retryable 决定要不要重试。"""


class LLMError(Exception):
    def __init__(self, kind: str, message: str = "", *, retryable: bool = False,
                 status: int | None = None):
        super().__init__(f"{kind}: {message}")
        self.kind = kind
        self.message = message
        self.retryable = retryable
        self.status = status


def from_status(status: int, message: str = "") -> LLMError:
    """按 HTTP 状态码归类。402 是 DeepSeek 的「余额不足」；OpenAI 余额不足是 429 + insufficient_quota。"""
    if status == 429 and "quota" in message.lower():
        return LLMError("balance", message, status=status)
    if status in (401, 403):
        return LLMError("auth", message, status=status)
    if status == 402:
        return LLMError("balance", message, status=status)
    if status == 404:
        return LLMError("model", message, status=status)
    if status == 429:
        return LLMError("rate", message, retryable=True, status=status)
    if status == 408:
        return LLMError("network", message, retryable=True, status=status)
    if status >= 500:
        return LLMError("overloaded", message, retryable=True, status=status)
    if status in (400, 413, 422):
        return LLMError("bad_request", message, status=status)
    return LLMError("other", message, status=status)
