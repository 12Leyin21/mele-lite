"""性格标签（traits，Tilia 09-28：模拟人生 4 那种感觉）。

每个标签：名字、一句说明（给挑的人看）、写进人设的一行（给它自己看），各分中英。
**清单还是空的**：Tilia回头把模拟人生的 traits 翻出来，一起挑、一起改措辞再填。
人设里存的是 id；清单里删掉的 id 读的时候跳过，不报错。"""
from __future__ import annotations

MAX_TRAITS = 3

# id → {"name": {lang: …}, "desc": {lang: …}, "line": {lang: …}}
TRAITS: dict[str, dict[str, dict[str, str]]] = {}


def catalog(lang: str) -> list[dict]:
    return [{"id": k, "name": v["name"][lang], "desc": v["desc"][lang]} for k, v in TRAITS.items()]


def check(ids: list) -> list[str]:
    """PATCH 时核对：最多 3 个、不重复、都在清单里。不对就 ValueError。"""
    if not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
        raise ValueError("traits must be a list of ids")
    if len(ids) > MAX_TRAITS or len(set(ids)) != len(ids):
        raise ValueError(f"at most {MAX_TRAITS} different traits")
    unknown = [i for i in ids if i not in TRAITS]
    if unknown:
        raise ValueError(f"unknown traits: {unknown}")
    return ids


def lines(ids: list[str], lang: str) -> list[str]:
    return [TRAITS[i]["line"][lang] for i in ids if i in TRAITS]
