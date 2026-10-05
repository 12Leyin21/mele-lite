"""人物卡「对谁隐藏」（10-01）：卡在账号名下大家共用，但 TA 可以让某几个联系人看不到某张卡——
翻不到（person_card get / memory_search）、不自动递（联想里的人物卡）、写不了（同名的那张）。"""
from __future__ import annotations

from uuid import UUID


async def hidden_for(pool, companion: UUID) -> frozenset[int]:
    """这个联系人看不到的那几张卡的编号。"""
    return frozenset(r["person_id"] for r in await pool.fetch(
        "SELECT person_id FROM person_hidden WHERE companion_id = $1", companion))


async def hidden_from(pool, person: int) -> list[UUID]:
    return [r["companion_id"] for r in await pool.fetch(
        "SELECT companion_id FROM person_hidden WHERE person_id = $1 ORDER BY companion_id", person)]


async def set_hidden(pool, account: UUID, person: int, companions: list[UUID]) -> None:
    """整个换掉：只认这个账号自己的联系人。"""
    async with pool.acquire() as con, con.transaction():
        await con.execute("DELETE FROM person_hidden WHERE person_id = $1", person)
        await con.execute(
            """INSERT INTO person_hidden (person_id, companion_id)
               SELECT $1, c.id FROM companions c WHERE c.account_id = $2 AND c.id = ANY($3::uuid[])""",
            person, account, list(companions))
