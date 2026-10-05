"""导入酒馆（SillyTavern）角色卡（10-01，设计 specs/2026-10-01-tavern-card-import-design.md）。

按公开规范读格式（Character Card V2：malfoyslastname/character-card-spec-v2；V3：kwaroran/character-card-spec-v3，MIT），
**酒馆本身的代码（AGPL）一行不看不抄**；解析自己写，只用标准库。

- PNG：文字块（tEXt）里 `ccv3`（V3）优先，其次 `chara`（V2 / V1），值是 base64 编码的 JSON；图本身当头像。
- JSON 文件：直接是卡。V2 / V3 字段在 `data` 里；V1 字段在顶层。
- 卡里的东西是数据：不执行任何东西，素材（.lua / .js / 音视频）一律不碰。"""
from __future__ import annotations

import base64
import binascii
import json
import re
import struct
import zlib
from dataclasses import dataclass, field

MAX_BYTES = 10 * 1024 * 1024
MAX_TEXT = 30_000
_PNG = b"\x89PNG\r\n\x1a\n"
_TEXT_FIELDS = ("name", "nickname", "description", "personality", "scenario", "first_mes", "mes_example",
                "system_prompt", "post_history_instructions", "creator_notes")


class CardError(ValueError):
    pass


@dataclass
class Card:
    name: str
    description: str = ""
    personality: str = ""
    scenario: str = ""
    greetings: list[str] = field(default_factory=list)     # first_mes 在最前，后面是 alternate_greetings
    mes_example: str = ""
    system_prompt: str = ""
    post_history: str = ""
    creator: str = ""
    creator_notes: str = ""
    tags: list[str] = field(default_factory=list)
    book: list[dict] = field(default_factory=list)          # character_book.entries 原样
    spec: str = "v1"
    image: bytes | None = None                             # PNG 卡的图（当头像）


def _png_texts(data: bytes) -> dict[str, str]:
    """PNG 的 tEXt / zTXt / iTXt 文字块 → {关键字: 文字}。"""
    out, i = {}, len(_PNG)
    while i + 8 <= len(data):
        n, kind = struct.unpack(">I4s", data[i:i + 8])
        body = data[i + 8:i + 8 + n]
        i += 12 + n
        try:
            if kind == b"tEXt":
                k, _, v = body.partition(b"\0")
                out[k.decode("latin-1")] = v.decode("latin-1")
            elif kind == b"zTXt":
                k, _, rest = body.partition(b"\0")
                out[k.decode("latin-1")] = zlib.decompress(rest[1:]).decode("latin-1")
            elif kind == b"iTXt":
                k, _, rest = body.partition(b"\0")
                flag, rest = rest[0], rest[2:]
                _, _, rest = rest.partition(b"\0")              # 语言标签
                _, _, text = rest.partition(b"\0")              # 翻译过的关键字
                out[k.decode("latin-1")] = (zlib.decompress(text) if flag else text).decode("utf-8")
        except (zlib.error, UnicodeDecodeError, IndexError):
            continue
        if kind == b"IEND":
            break
    return out


def _b64_json(s: str) -> dict:
    try:
        return json.loads(base64.b64decode(s.strip()).decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as e:
        raise CardError("卡里的数据读不出来") from e


def _s(v) -> str:
    return v.strip() if isinstance(v, str) else ""


def _from_obj(obj: dict) -> Card:
    if not isinstance(obj, dict):
        raise CardError("这不是一张角色卡")
    spec = str(obj.get("spec") or "")
    d = obj.get("data") if isinstance(obj.get("data"), dict) else obj
    name = _s(d.get("nickname")) or _s(d.get("name"))
    if not name:
        raise CardError("这张卡没有名字，读不出来")
    if sum(len(_s(d.get(k))) for k in _TEXT_FIELDS) > MAX_TEXT:
        raise CardError(f"这张卡的文字太长了（超过 {MAX_TEXT} 字）")
    alts = [x.strip() for x in (d.get("alternate_greetings") or []) if isinstance(x, str) and x.strip()]
    first = _s(d.get("first_mes"))
    book = (d.get("character_book") or {}).get("entries") if isinstance(d.get("character_book"), dict) else None
    return Card(
        name=name[:20], description=_s(d.get("description")), personality=_s(d.get("personality")),
        scenario=_s(d.get("scenario")), greetings=([first] if first else []) + alts, mes_example=_s(d.get("mes_example")),
        system_prompt=_s(d.get("system_prompt")), post_history=_s(d.get("post_history_instructions")),
        creator=_s(d.get("creator"))[:60], creator_notes=_s(d.get("creator_notes"))[:2000],
        tags=[t.strip()[:30] for t in (d.get("tags") or []) if isinstance(t, str) and t.strip()][:20],
        book=[e for e in (book or []) if isinstance(e, dict)],
        spec="v3" if spec == "chara_card_v3" else "v2" if spec == "chara_card_v2" else "v1")


def parse(data: bytes) -> Card:
    """读一张卡（PNG 或 JSON）。读不出来抛 CardError（话是给用户看的）。"""
    if len(data) > MAX_BYTES:
        raise CardError("文件太大了（最多 10MB）")
    if data.startswith(_PNG):
        texts = _png_texts(data)
        raw = texts.get("ccv3") or texts.get("chara")
        if not raw:
            raise CardError("这张图里没有角色卡的数据")
        card = _from_obj(_b64_json(raw))
        card.image = data
        return card
    try:
        obj = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise CardError("只认 PNG 角色卡或 JSON 角色卡") from e
    return _from_obj(obj)


_CHAR = re.compile(r"\{\{\s*char\s*\}\}|<BOT>|<CHAR>", re.I)
_USER = re.compile(r"\{\{\s*user\s*\}\}|<USER>", re.I)


def fill(text: str, char: str, user: str) -> str:
    """宏：{{char}} → 角色名，{{user}} → TA 的名字；{{original}} 拿掉（那是酒馆自己的系统提示词，我们没有）。"""
    text = re.sub(r"\{\{\s*original\s*\}\}", "", text or "", flags=re.I)
    return _USER.sub(user, _CHAR.sub(char, text)).strip()


_HEADS = {"zh": {"desc": "## 角色", "personality": "性格：", "scenario": "## 场景",
                 "example": "## 说话示例", "author": "## 作者对这个角色的说明", "you": "你"},
          "en": {"desc": "## Character", "personality": "Personality: ", "scenario": "## Scenario",
                 "example": "## How they talk (examples)", "author": "## The author's notes on this character", "you": "you"}}


def persona_text(card: Card, user_name: str, lang: str) -> str:
    """拼成「导入的人设」那份（进人设那一层；产品底子和说明书在它前面，卡改不了）。post_history_instructions 不用。"""
    h = _HEADS["zh" if lang == "zh" else "en"]
    user = user_name or h["you"]
    f = lambda t: fill(t, card.name, user)            # noqa: E731
    parts = []
    body = "\n".join(x for x in (f(card.description), f"{h['personality']}{f(card.personality)}" if card.personality else "") if x)
    if body:
        parts.append(f"{h['desc']}\n{body}")
    if card.scenario:
        parts.append(f"{h['scenario']}\n{f(card.scenario)}")
    example = f(card.mes_example.replace("<START>", "").replace("<start>", ""))
    if example:
        parts.append(f"{h['example']}\n{example}")
    author = f(card.system_prompt)
    if author:
        parts.append(f"{h['author']}\n{author}")
    return "\n\n".join(parts)


def lore_entries(card: Card, user_name: str, lang: str) -> tuple[list[dict], int]:
    """卡里的世界书 → 我们的词条（name / keywords / content / enabled / constant）。返回（能用的, 跳过了几条）。
    两组关键词合成一组；太短的关键词丢掉（单个汉字可以，单个字母不行）；一个关键词都不剩、内容为空的跳过。"""
    from .lore import CONTENT_MAX, KEYWORDS_MAX, NAME_MAX, keyword_ok, norm
    user = user_name or _HEADS["zh" if lang == "zh" else "en"]["you"]
    out, skipped = [], 0
    for e in card.book:
        keys = [k for k in [*(e.get("keys") or []), *(e.get("secondary_keys") or [])] if isinstance(k, str)]
        seen, kws = set(), []
        for k in keys:
            k = " ".join(fill(k, card.name, user).split())
            if keyword_ok(k) and norm(k) not in seen:
                seen.add(norm(k))
                kws.append(k[:40])
        content = fill(_s(e.get("content")), card.name, user)[:CONTENT_MAX]
        constant = bool(e.get("constant"))
        if not content or (not kws and not constant):
            skipped += 1
            continue
        name = (_s(e.get("comment")) or _s(e.get("name")) or (kws[0] if kws else card.name))[:NAME_MAX]
        out.append({"name": name, "keywords": (kws or [card.name])[:KEYWORDS_MAX], "content": content,
                    "enabled": e.get("enabled") is not False, "constant": constant})
    return out, skipped


def preview(card: Card, user_name: str, lang: str) -> dict:
    """导入前给 TA 看的：名字、作者和作者的话、标签、开场白（挑一句）、世界书几条、作者指令原文、人设多长。"""
    user = user_name or _HEADS["zh" if lang == "zh" else "en"]["you"]
    entries, skipped = lore_entries(card, user_name, lang)
    return {"name": card.name, "creator": card.creator, "creator_notes": card.creator_notes, "tags": card.tags,
            "greetings": [fill(g, card.name, user) for g in card.greetings][:20],
            "lore": len(entries), "lore_skipped": skipped, "has_image": card.image is not None,
            "system_prompt": card.system_prompt, "post_history": card.post_history, "spec": card.spec,
            "persona_chars": len(persona_text(card, user_name, lang))}
