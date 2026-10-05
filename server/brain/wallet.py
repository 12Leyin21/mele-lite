"""钱包记账（10-02）。先按默认做了一版，晚上Tilia补了要的：能切人民币、也记收入、它偶尔提一句、每天一张小票、
标签自己写——写过的存进标签栏，下次直接点，显示时按标签归类。

- 一笔：支出 / 收入、金额（存「分」）、标签、一句备注、哪天。TA 在钱包页记，也可以在聊天里说「刚买咖啡花了 6 块」，它用工具替 TA 记。
- 一个月：支出、收入、结余、跟上个月比、按标签分、按天列；可选预算。
- 小票：某一天的支出 + 收入，一张像刷卡机打出来的单子（App 画）。
- 偶尔提一句：TA 自己记的、它还没听说的，隔半天以上才在〔钱包〕里递给它一次，它想提就随口提，不评判花多花少。"""
from __future__ import annotations

import json
from datetime import date, datetime, timedelta
from uuid import UUID

DEFAULT_CATEGORIES = ["吃饭", "交通", "购物", "娱乐", "学习", "其他"]
DEFAULT_INCOME = ["零花钱", "打工", "红包", "其他收入"]
KINDS = ("out", "in")
TELL_GAP = timedelta(hours=12)
CURRENCIES = {"AUD": "A$", "CNY": "¥", "USD": "US$", "EUR": "€", "GBP": "£", "JPY": "¥", "HKD": "HK$", "NZD": "NZ$"}
MAX_AMOUNT = 10_000_000_00          # 一千万，防手滑


class WalletError(ValueError):
    pass


def cents(v) -> int:
    """「6」「6.5」「6.50」「1,200」→ 分"""
    try:
        n = round(float(str(v).replace(",", "").replace("，", "").strip()) * 100)
    except (TypeError, ValueError):
        raise WalletError("金额写成数字，比如 6.5") from None
    if n <= 0 or n > MAX_AMOUNT:
        raise WalletError("金额不对")
    return n


def _custom(raw) -> dict:
    """自己写过的标签：{"out": [...], "in": [...]}（老数据是一个列表 = 支出的）"""
    v = json.loads(raw) if isinstance(raw, str) else (raw or [])
    if isinstance(v, list):
        return {"out": [str(x) for x in v], "in": []}
    return {"out": [str(x) for x in v.get("out", [])], "in": [str(x) for x in v.get("in", [])]}


async def settings(pool, account: UUID) -> dict:
    r = await pool.fetchrow("SELECT currency, budget, categories FROM wallet_settings WHERE account_id = $1", account)
    custom = _custom(r["categories"]) if r else {"out": [], "in": []}
    cur = r["currency"] if r else "AUD"
    return {"currency": cur, "symbol": CURRENCIES.get(cur, cur), "budget": r["budget"] if r else 0,
            "categories": DEFAULT_CATEGORIES + [c for c in custom["out"] if c not in DEFAULT_CATEGORIES],
            "income_categories": DEFAULT_INCOME + [c for c in custom["in"] if c not in DEFAULT_INCOME],
            "custom": custom}


async def save_settings(pool, account: UUID, *, currency: str | None = None, budget=None, custom=None) -> dict:
    cur = await settings(pool, account)
    if currency is not None:
        currency = currency.upper()
        if currency not in CURRENCIES:
            raise WalletError("这个币种还不认")
        cur["currency"] = currency
    if budget is not None:
        cur["budget"] = 0 if budget in (0, "0", "", None) else cents(budget)
    if custom is not None:
        c = _custom(custom)
        cur["custom"] = {k: [t.strip()[:12] for t in c[k] if t and t.strip()][:30] for k in KINDS}
    await pool.execute("""INSERT INTO wallet_settings (account_id, currency, budget, categories) VALUES ($1, $2, $3, $4::jsonb)
                          ON CONFLICT (account_id) DO UPDATE SET currency = $2, budget = $3, categories = $4::jsonb""",
                       account, cur["currency"], cur["budget"], json.dumps(cur["custom"], ensure_ascii=False))
    return await settings(pool, account)


async def _remember_tag(pool, account: UUID, kind: str, tag: str) -> None:
    """写了一个新标签：存进标签栏，下次直接点"""
    s = await settings(pool, account)
    if tag in (s["categories"] if kind == "out" else s["income_categories"]):
        return
    custom = s["custom"]
    custom[kind] = custom[kind] + [tag]
    await save_settings(pool, account, custom=custom)


def _row(r) -> dict:
    return {"id": r["id"], "kind": r["kind"], "amount": r["amount"], "category": r["category"], "note": r["note"],
            "day": r["day"].isoformat(), "author": r["author"], "created_at": r["created_at"].isoformat()}


_COLS = "id, kind, amount, category, note, day, author, created_at"


async def add(pool, account: UUID, *, amount, category: str, note: str = "", day: date, author: str = "user",
              kind: str = "out", now: datetime) -> dict:
    if kind not in KINDS:
        raise WalletError("只能是支出（out）或收入（in）")
    n = cents(amount)
    tag = (category or "").strip()[:12] or ("其他" if kind == "out" else "其他收入")
    await _remember_tag(pool, account, kind, tag)
    r = await pool.fetchrow(f"""INSERT INTO wallet_entries (account_id, kind, amount, category, note, day, author, told, created_at)
                                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING {_COLS}""",
                            account, kind, n, tag, note.strip()[:200], day, author, author != "user", now)
    return _row(r)


async def update(pool, account: UUID, eid: int, *, amount=None, category: str | None = None, note: str | None = None,
                 day: date | None = None) -> dict | None:
    if category:
        kind = await pool.fetchval("SELECT kind FROM wallet_entries WHERE account_id = $1 AND id = $2", account, eid)
        if kind:
            await _remember_tag(pool, account, kind, category.strip()[:12])
    r = await pool.fetchrow(f"""UPDATE wallet_entries SET amount = COALESCE($3, amount), category = COALESCE($4, category),
                                note = COALESCE($5, note), day = COALESCE($6, day)
                                WHERE account_id = $1 AND id = $2 RETURNING {_COLS}""",
                            account, eid, cents(amount) if amount is not None else None,
                            category.strip() if category else None, note.strip()[:200] if note is not None else None, day)
    return _row(r) if r else None


async def delete(pool, account: UUID, eid: int) -> bool:
    return (await pool.execute("DELETE FROM wallet_entries WHERE account_id = $1 AND id = $2", account, eid)) != "DELETE 0"


def _month_range(month: date) -> tuple[date, date]:
    start = month.replace(day=1)
    end = (start + timedelta(days=32)).replace(day=1)
    return start, end


async def month(pool, account: UUID, month: date) -> dict:
    start, end = _month_range(month)
    prev_start, _ = _month_range(start - timedelta(days=1))
    rows = await pool.fetch(f"SELECT {_COLS} FROM wallet_entries WHERE account_id = $1 AND day >= $2 AND day < $3 "
                            "ORDER BY day DESC, id DESC", account, start, end)
    last = await pool.fetchval("SELECT COALESCE(sum(amount), 0) FROM wallet_entries WHERE account_id = $1 AND kind = 'out' "
                               "AND day >= $2 AND day < $3", account, prev_start, start)
    by = {"out": {}, "in": {}}
    for r in rows:
        by[r["kind"]][r["category"]] = by[r["kind"]].get(r["category"], 0) + r["amount"]
    s = await settings(pool, account)
    out, inc = sum(by["out"].values()), sum(by["in"].values())

    def ranked(d):
        return sorted(([k, v] for k, v in d.items()), key=lambda kv: -kv[1])
    return {"month": start.isoformat()[:7], "total": out, "income": inc, "net": inc - out, "last_month": last,
            "by_category": ranked(by["out"]), "by_income": ranked(by["in"]),
            "entries": [_row(r) for r in rows], **s}


async def receipt(pool, account: UUID, day: date) -> dict:
    """一天的小票：那天的每一笔（按记的先后）、支出、收入、结余"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM wallet_entries WHERE account_id = $1 AND day = $2 ORDER BY created_at, id",
                            account, day)
    out = sum(r["amount"] for r in rows if r["kind"] == "out")
    inc = sum(r["amount"] for r in rows if r["kind"] == "in")
    no = await pool.fetchval("SELECT count(DISTINCT day) FROM wallet_entries WHERE account_id = $1 AND day <= $2", account, day)
    s = await settings(pool, account)
    return {"day": day.isoformat(), "no": no, "entries": [_row(r) for r in rows], "out": out, "income": inc,
            "net": inc - out, "currency": s["currency"], "symbol": s["symbol"]}


async def pending_note(pool, account: UUID, now: datetime, lang: str) -> str:
    """〔钱包〕：TA 自己记的、它还没听说的。离上次提过半天以上才给一次（Tilia：偶尔提一句）。"""
    told_at = await pool.fetchval("SELECT told_at FROM wallet_settings WHERE account_id = $1", account)
    if told_at and now - told_at < TELL_GAP:
        return ""
    rows = await pool.fetch(f"UPDATE wallet_entries SET told = TRUE WHERE account_id = $1 AND NOT told RETURNING {_COLS}", account)
    if not rows:
        return ""
    s = await settings(pool, account)
    await pool.execute("""INSERT INTO wallet_settings (account_id, told_at) VALUES ($1, $2)
                          ON CONFLICT (account_id) DO UPDATE SET told_at = $2""", account, now)
    sym = s["symbol"]
    items = [("+" if r["kind"] == "in" else "") + f"{r['category']} {money(r['amount'], sym)}" + (f"（{r['note']}）" if r["note"] else "")
             for r in sorted(rows, key=lambda r: r["created_at"])[-8:]]
    m = await month(pool, account, max(r["day"] for r in rows))
    budget = f"，预算 {money(m['budget'], sym)}" if m["budget"] else ""
    if lang == "zh":
        return (f"〔钱包〕TA 最近记了：{'、'.join(items)}。这个月花了 {money(m['total'], sym)}{budget}。"
                "想提就随口提一句（像朋友那样，不评判花多花少、不说教）。")
    budget = f", budget {money(m['budget'], sym)}" if m["budget"] else ""
    return (f"〔Wallet〕They recently logged: {', '.join(items)}. Spent {money(m['total'], sym)} this month{budget}. "
            "Mention it in passing if you feel like it (like a friend — no judging, no lecturing).")


def money(amount: int, symbol: str) -> str:
    return f"{symbol}{amount / 100:,.2f}".replace(".00", "")


async def export(pool, account: UUID) -> list[dict]:
    rows = await pool.fetch(f"SELECT {_COLS} FROM wallet_entries WHERE account_id = $1 ORDER BY day, id", account)
    return [_row(r) for r in rows]
