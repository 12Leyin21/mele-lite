"""查营养：Open Food Facts（免费、开放数据，不要钥匙；数据 © Open Food Facts contributors，ODbL）。
搬自 fed-myself 的 /food/barcode、/food/lookup。传输可以换成假的（测试里用）。Woolworths 那套不进 Mele。"""
from __future__ import annotations

import asyncio

from . import logic as L

UA = {"User-Agent": "Mele/0.1 (food diary; https://mele.chat)"}
FIELDS = "product_name,brands,nutriments,serving_size"


class OffDown(RuntimeError):
    """每个站都没回（不是「没查到」）：app 要说清楚，别当成没结果。"""


def httpx_get():
    import httpx

    async def get(url: str, params: dict) -> tuple[int, dict]:
        async with httpx.AsyncClient(timeout=12, headers=UA) as client:
            r = await client.get(url, params=params)
        return r.status_code, (r.json() if r.status_code == 200 else {})
    return get


async def barcode(code: str, get=None) -> dict:
    get = get or httpx_get()
    code = "".join(ch for ch in code if ch.isdigit())[:14]
    if len(code) < 8:
        raise ValueError("条码不对")
    for _ in range(2):
        try:
            status, d = await get(f"https://world.openfoodfacts.org/api/v2/product/{code}.json", {"fields": FIELDS})
        except Exception:                                   # noqa: BLE001 —— 网络抖一下，再试一次
            await asyncio.sleep(0.5)
            continue
        if status == 404:
            break
        if status != 200:
            await asyncio.sleep(0.5)
            continue
        found = L.off_products({"products": [d.get("product") or {}]}) if d.get("status") == 1 else []
        return {"found": bool(found), "product": found[0] if found else None, "code": code}
    return {"found": False, "product": None, "code": code}


async def search(q: str, country: str = "world", limit: int = 5, get=None) -> dict:
    get = get or httpx_get()
    q, limit = q.strip()[:80], max(1, min(20, limit))
    if not q:
        raise ValueError("查什么？")
    country = "".join(ch for ch in (country or "").lower() if ch.isalpha())[:8] or "world"
    params = {"search_terms": q, "search_simple": 1, "json": 1, "page_size": max(12, limit * 2), "fields": FIELDS}
    hosts = [f"{country}.openfoodfacts.org"] + (["world.openfoodfacts.org"] if country != "world" else [])
    answered = False
    for host in hosts:
        for _ in range(2):                                  # 忙的时候会回 503，再试一次就够
            try:
                status, d = await get(f"https://{host}/cgi/search.pl", params)
            except Exception:                               # noqa: BLE001
                await asyncio.sleep(0.5)
                continue
            if status != 200:
                await asyncio.sleep(0.5)
                continue
            answered = True
            found = L.off_products(d, limit=limit)
            if found:
                return {"source": f"Open Food Facts ({host.split('.')[0]})", "products": found,
                        "lines": [L.off_line(p) for p in found]}
            break
    if not answered:
        raise OffDown("Open Food Facts 现在没回，过一会儿再试")
    return {"source": "Open Food Facts", "products": [], "lines": []}
