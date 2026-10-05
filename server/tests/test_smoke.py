import numpy as np


async def test_schema_and_vector_roundtrip(pool, user_a):
    v = np.zeros(1024, dtype=np.float32)
    v[3] = 1.0
    row = await pool.fetchrow(
        "INSERT INTO memories (user_id, content, embedding) VALUES ($1, $2, $3) "
        "RETURNING id, embedding",
        user_a, "hello", v,
    )
    assert row["id"] == 1
    assert float(row["embedding"][3]) == 1.0
