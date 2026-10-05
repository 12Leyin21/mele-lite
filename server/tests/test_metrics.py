"""一测的信任指标（09-30）：第几天开始说自己的事 ↔ 留存。测试用小满 / Mia。"""
from datetime import datetime, timedelta, timezone

from brain import accounts
from brain import metrics as T

NOW = datetime(2026, 11, 15, tzinfo=timezone.utc)


async def seed(pool, *, age: int, about: int | None, person: int | None, said: list[int]):
    start = NOW - timedelta(days=age)
    acc = await accounts.create_account(pool)
    await pool.execute("UPDATE accounts SET created_at = $2 WHERE id = $1", acc, start)
    comp = await accounts.create_companion(pool, acc)
    conv = await accounts.new_conversation(pool, acc, comp)
    if about is not None:
        await pool.execute("INSERT INTO memories (user_id, content, kind, created_at) VALUES ($1, '爱喝燕麦拿铁', 'about', $2)",
                           comp, start + timedelta(days=about, hours=1))
    if person is not None:
        await pool.execute("INSERT INTO memories (user_id, content, kind, created_at) VALUES ($1, '妈妈', 'person', $2)",
                           acc, start + timedelta(days=person, hours=1))
    for d in said:
        await pool.execute("INSERT INTO chat_messages (user_id, role, text, created_at) VALUES ($1, 'user', '在吗', $2)",
                           conv, start + timedelta(days=d, hours=2))
    return acc


async def test_trust_rows_and_summary(pool):
    a = await seed(pool, age=20, about=1, person=5, said=[0, 1, 2, 8, 15])       # 早说、留下来了
    b = await seed(pool, age=20, about=None, person=6, said=[0, 3])               # 晚说、走了
    c = await seed(pool, age=4, about=0, person=None, said=[0, 1])                # 才注册 4 天：还看不出留存
    rows = {r.account: r for r in await T.trust(pool, NOW)}
    ra, rb, rc = rows[a], rows[b], rows[c]
    assert (ra.first_about, ra.first_person, ra.first_shared, ra.active_days, ra.last_active) == (1, 5, 1, 5, 15)
    assert (ra.came_back(7), ra.came_back(14)) == (True, True)
    assert (rb.first_shared, rb.came_back(7)) == (6, False)
    assert (rc.first_shared, rc.came_back(7)) == (0, None)
    s = T.summary(list(rows.values()), 7)
    assert s["early"] == (1, 1) and s["late"] == (0, 1)
    text = T.render(list(rows.values()))
    assert "前 3 天就说了自己的事 1/1，没说的 0/1" in text and "@" not in text
