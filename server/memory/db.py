"""连接池和建表。

每个连接一建立就注册 pgvector 的类型，这样 numpy 数组能直接当 vector 参数传、
查出来的 vector 列直接是 numpy 数组。注意：必须先 apply_schema（建扩展）再 create_pool。
"""
from pathlib import Path

import asyncpg
from pgvector import Vector
from pgvector.asyncpg import register_vector

SCHEMA_FILE = Path(__file__).with_name("schema.sql")


async def _init_connection(conn: asyncpg.Connection) -> None:
    await register_vector(conn)
    # pgvector 0.5 起查出来的是 Vector 对象；改回 numpy 数组，上层代码直接拿来算
    await conn.set_type_codec(
        "vector",
        encoder=lambda v: (v if isinstance(v, Vector) else Vector(v)).to_binary(),
        decoder=lambda b: Vector.from_binary(b).to_numpy(),
        format="binary",
    )


async def create_pool(dsn: str, **kwargs) -> asyncpg.Pool:
    return await asyncpg.create_pool(dsn, init=_init_connection, **kwargs)


async def apply_schema(dsn: str) -> None:
    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute(SCHEMA_FILE.read_text(encoding="utf-8"))
    finally:
        await conn.close()
