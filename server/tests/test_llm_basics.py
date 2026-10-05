import pytest

from llm.catalog import CATALOG, cost, lookup
from llm.errors import from_status
from llm.types import Usage


def test_usage_add_and_prompt_total():
    u = Usage(10, 20, 30, 5) + Usage(1, 2, 3, 4)
    assert (u.input, u.cache_read, u.cache_write, u.output) == (11, 22, 33, 9)
    assert u.prompt_total == 66
    assert (Usage(cache_known=False) + Usage()).cache_known is False


def test_cost_known_and_unknown():
    assert cost(Usage(input=1_000_000), "deepseek-flash") == pytest.approx(0.30)
    assert cost(Usage(cache_read=1_000_000, output=1_000_000), "claude-sonnet-5") == pytest.approx(10.20)
    assert cost(Usage(input=5), "some-custom-model") is None


def test_deepseek_off_peak_is_half_price():
    from datetime import datetime, timezone
    peak = datetime(2026, 10, 1, 2, 0, tzinfo=timezone.utc)          # 周四 UTC 02:00
    night = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)        # 周四 UTC 12:00
    weekend = datetime(2026, 10, 3, 2, 0, tzinfo=timezone.utc)       # 周六，全天平峰
    u = Usage(input=1_000_000)
    assert cost(u, "deepseek-flash", at=peak) == pytest.approx(0.30)
    assert cost(u, "deepseek-flash", at=night) == pytest.approx(0.15)
    assert cost(u, "deepseek-flash", at=weekend) == pytest.approx(0.15)
    assert cost(Usage(output=1_000_000), "claude-sonnet-5", at=night) == pytest.approx(10.00)   # 别家不打折


def test_every_ledger_model_is_in_catalog():
    for m in CATALOG.values():
        assert lookup(m.ledger_model) is not None and lookup(m.age_model) is not None


@pytest.mark.parametrize("status,kind,retry", [
    (401, "auth", False), (403, "auth", False), (402, "balance", False), (404, "model", False),
    (429, "rate", True), (408, "network", True), (500, "overloaded", True), (529, "overloaded", True),
    (400, "bad_request", False), (418, "other", False),
])
def test_from_status(status, kind, retry):
    e = from_status(status, "x")
    assert (e.kind, e.retryable, e.status) == (kind, retry, status)


def test_quota_429_is_balance_and_not_retried():
    e = from_status(429, "You exceeded your current quota (insufficient_quota)")
    assert e.kind == "balance" and not e.retryable
