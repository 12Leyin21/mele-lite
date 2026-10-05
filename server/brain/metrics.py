"""一测看「信任」（09-30，Instinct 借的，Tilia要）：第几天开始跟它说自己的事 ↔ 留存。只在后台多看一个数，不进 App。

「说自己的事」看两样它记下的：第一条「关于 TA」（TA 的日常小事）、第一张人物卡（TA 身边的人）。
天数都从注册那一刻起算（第 0 天 = 注册后 24 小时内），不按时区切，一测够用。

用法：`.venv/bin/python -m brain.metrics`（读 NEWAPP_DSN / server/.local/api.env；--emails 才显示邮箱）"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from uuid import UUID

EARLY_DAYS = 3          # 前 3 天就说了自己的事 = 「早」


@dataclass
class Trust:
    account: UUID
    email: str
    age_days: int                 # 注册多少天了
    first_about: int | None       # 第几天有了第一条「关于 TA」
    first_person: int | None      # 第几天有了第一张人物卡
    active_days: int              # 有几天说过话
    last_active: int | None       # 最后一次说话是第几天

    @property
    def first_shared(self) -> int | None:
        days = [d for d in (self.first_about, self.first_person) if d is not None]
        return min(days) if days else None

    def came_back(self, day: int) -> bool | None:
        """第 day 天及以后还来过吗；注册还不到 day 天 = 还看不出来（None）。"""
        if self.age_days < day:
            return None
        return self.last_active is not None and self.last_active >= day


def _day(at: datetime | None, start: datetime) -> int | None:
    return None if at is None else max(0, (at - start).days)


async def trust(pool, now: datetime) -> list[Trust]:
    out = []
    for a in await pool.fetch("SELECT id, email, created_at FROM accounts ORDER BY created_at"):
        start = a["created_at"]
        about = await pool.fetchval(
            "SELECT min(m.created_at) FROM memories m JOIN companions c ON c.id = m.user_id "
            "WHERE c.account_id = $1 AND m.kind = 'about'", a["id"])
        person = await pool.fetchval("SELECT min(created_at) FROM memories WHERE user_id = $1 AND kind = 'person'", a["id"])
        said = [r["at"] for r in await pool.fetch(
            "SELECT m.created_at AS at FROM chat_messages m JOIN conversations v ON v.id = m.user_id "
            "JOIN companions c ON c.id = v.companion_id WHERE c.account_id = $1 AND m.role = 'user'", a["id"])]
        days = {_day(t, start) for t in said}
        out.append(Trust(a["id"], a["email"] or "", _day(now, start), _day(about, start), _day(person, start),
                         len(days), max(days) if days else None))
    return out


def summary(rows: list[Trust], day: int = 7) -> dict:
    """前 EARLY_DAYS 天就说了自己的事的人 vs 没说的人，第 day 天还回来的比例。"""
    def rate(group):
        known = [r.came_back(day) for r in group if r.came_back(day) is not None]
        return (sum(known), len(known))
    early = [r for r in rows if r.first_shared is not None and r.first_shared < EARLY_DAYS]
    late = [r for r in rows if r not in early]
    return {"day": day, "early": rate(early), "late": rate(late)}


def render(rows: list[Trust], emails: bool = False) -> str:
    lines = ["账号      注册天数  关于TA  人物卡  说话天数  最后一天  D7  D14"]
    mark = {True: "✓", False: "✗", None: "·"}
    for r in rows:
        who = r.email if emails else str(r.account)[:8]
        cell = lambda v: "-" if v is None else str(v)          # noqa: E731
        lines.append(f"{who:<9} {r.age_days:>6}  {cell(r.first_about):>6}  {cell(r.first_person):>6}  "
                     f"{r.active_days:>6}  {cell(r.last_active):>6}   {mark[r.came_back(7)]}   {mark[r.came_back(14)]}")
    for d in (7, 14):
        s = summary(rows, d)
        lines.append(f"第 {d} 天还回来：前 {EARLY_DAYS} 天就说了自己的事 {s['early'][0]}/{s['early'][1]}，"
                     f"没说的 {s['late'][0]}/{s['late'][1]}")
    return "\n".join(lines)


if __name__ == "__main__":
    import asyncio
    import os
    import sys
    from datetime import timezone
    from pathlib import Path

    import memory as M
    from api.__main__ import load_env_file

    async def main():
        load_env_file(Path(__file__).resolve().parent.parent / ".local" / "api.env")
        pool = await M.create_pool(os.environ["NEWAPP_DSN"])
        try:
            print(render(await trust(pool, datetime.now(timezone.utc)), emails="--emails" in sys.argv))
        finally:
            await pool.close()
    asyncio.run(main())
