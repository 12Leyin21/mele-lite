"""Mele Host 命令行（10-04）。在 Host 的容器里跑：
    python -m api.host pair            # 出一张新配对码并打印（旧的没用过的作废）
    python -m api.host status          # 有没有主人、有没有没用的码
    python -m api.host warm            # 预先下载记忆模型 bge-m3（约 2.3GB），免得第一次聊天卡住

配对码只在出的那一刻看得到原文（库里只存哈希），所以 `pair` 每次都出一张新的。"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Mapping
from urllib.parse import quote

from brain import host


@dataclass
class Flags:
    host: bool
    rerank: bool
    public_url: str


def flags(environ: Mapping[str, str]) -> Flags:
    return Flags(host=environ.get("NEWAPP_HOST", "0") == "1",
                 rerank=environ.get("NEWAPP_RERANK", "0") == "1",
                 public_url=environ.get("NEWAPP_PUBLIC_URL", "").strip().rstrip("/"))


def pairing_link(public_url: str, code: str) -> str:
    return f"mele://host?u={quote(public_url, safe='')}&c={code}"


async def ensure_code(pool, *, secret: str) -> str | None:
    """新服务器（没主人、也没码）出一张；其他情况不动。返回新码或 None。"""
    if await host.owner(pool) is not None or await host.has_code(pool):
        return None
    return await host.new_code(pool, secret=secret, now=datetime.now(timezone.utc))


def announce(public_url: str, code: str) -> None:
    print("\n=== Mele Host 配对码 ===", flush=True)
    print(f"配对码：{code}", flush=True)
    if public_url:
        print(f"地址：{public_url}", flush=True)
        print(f"配对链接（App 扫二维码用）：{pairing_link(public_url, code)}", flush=True)
    print("在 Mele Lite → Me → Mele Host 里扫码或手动输入。用一次就作废。\n", flush=True)


async def _main(args) -> int:
    if args.cmd == "warm":
        from memory.embed import BgeM3Embedder
        print("下载 / 加载记忆模型 bge-m3（第一次约 2.3GB）……", flush=True)
        BgeM3Embedder().embed(["你好"])
        print("好了。", flush=True)
        return 0
    dsn, secret = os.environ.get("NEWAPP_DSN", ""), os.environ.get("NEWAPP_SECRET", "")
    if not dsn or not secret:
        print("缺 NEWAPP_DSN / NEWAPP_SECRET（在 Host 的容器里跑：mele-host pair）", file=sys.stderr)
        return 2
    import memory as M
    from brain import archive
    await M.apply_schema(dsn)
    await archive.apply_brain_schema(dsn)
    pool = await M.create_pool(dsn)
    try:
        if args.cmd == "status":
            print(f"主人：{'已配对' if await host.owner(pool) else '还没有'}；"
                  f"没用的配对码：{'有' if await host.has_code(pool) else '没有'}")
            return 0
        code = await host.new_code(pool, secret=secret, now=datetime.now(timezone.utc))
        announce(flags(os.environ).public_url, code)
        return 0
    finally:
        await pool.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(prog="python -m api.host")
    ap.add_argument("cmd", choices=["pair", "status", "warm"])
    sys.exit(asyncio.run(_main(ap.parse_args())))
