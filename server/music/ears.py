"""Lumi 的耳朵（09-30，设计 specs/2026-09-30-ears-design.md，移植自之前自用的 App song_ears + gemini_ears，作者 12Leyin21）。

一首歌只听一次，全服务器共用（表 song_ears）：Apple 30 秒试听 → librosa 量数字（ears_numbers）+ Gemini 真听一遍写听感
→ lrclib 取带时间的歌词。TA 在 Mele 里说话时，按手机报的「放到第几秒」拼一行〔在听〕：换歌后第一句给整段，之后只给两行歌词。

一起听是甜点：任何一步失败都吞掉、记日志，不影响聊天。没听成就说没听过，不装。"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

import httpx

log = logging.getLogger(__name__)

LRCLIB = "https://lrclib.net/api"
_UA = {"User-Agent": "Mele/0.1 (https://mele.chat)"}
GEMINI = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
# Tilia 09-30：先用最便宜的，写得不好再往上换（之前自用的 App是按顺序试 flash-latest → 3.6 → 3.5 → flash-lite）
MODELS = [m.strip() for m in os.environ.get("NEWAPP_EARS_MODEL", "gemini-3.5-flash-lite").split(",") if m.strip()]
_RETRYABLE = {404, 429, 500, 503}
IMPRESSION_MAX = 400
# launchd 起的服务器 PATH 里没有 Homebrew：先看环境变量，再找 PATH，最后试 Homebrew 的位置
FFMPEG = os.environ.get("NEWAPP_FFMPEG") or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"


# ---- 档案 ----------------------------------------------------------------------------------------

def _j(v, default):
    if v is None:
        return default
    return json.loads(v) if isinstance(v, str) else v


async def get(pool, song_id: str) -> dict | None:
    r = await pool.fetchrow("SELECT * FROM song_ears WHERE song_id = $1", song_id)
    if r is None:
        return None
    d = dict(r)
    d["numbers"] = _j(d["numbers"], None)
    d["impression"] = _j(d["impression"], {})
    d["lyrics"] = _j(d["lyrics"], [])
    return d


async def save(pool, song_id: str, *, name: str, artist: str, duration_s: int, numbers: dict | None,
               impression: dict, lyrics: list, lyrics_source: str, status: str, now: datetime) -> None:
    await pool.execute(
        """INSERT INTO song_ears (song_id, name, artist, duration_s, numbers, impression, lyrics, lyrics_source, status, heard_at)
           VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb, $7::jsonb, $8, $9, $10)
           ON CONFLICT (song_id) DO UPDATE SET name = $2, artist = $3, duration_s = $4, numbers = $5::jsonb,
             impression = $6::jsonb, lyrics = $7::jsonb, lyrics_source = $8, status = $9, heard_at = $10""",
        song_id, name, artist, duration_s, None if numbers is None else json.dumps(numbers, ensure_ascii=False),
        json.dumps(impression, ensure_ascii=False), json.dumps(lyrics, ensure_ascii=False), lyrics_source, status, now)


async def add_impression(pool, song_id: str, lang: str, text: str) -> None:
    await pool.execute("UPDATE song_ears SET impression = impression || $2::jsonb WHERE song_id = $1",
                       song_id, json.dumps({lang: text}, ensure_ascii=False))


# ---- 歌词（lrclib，内测用；上架前换有授权的）----------------------------------------------------------

_STAMP = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")


def parse_lrc(text: str) -> list[dict]:
    """「[01:02.30] 一句」→ [{t: 62.3, line: "一句"}]，按时间排；一行多个时间戳各算一次；空词跳过。"""
    out = []
    for raw in (text or "").splitlines():
        stamps = _STAMP.findall(raw)
        line = _STAMP.sub("", raw).strip()
        if not stamps or not line:
            continue
        for m, s in stamps:
            out.append({"t": round(int(m) * 60 + float(s), 2), "line": line})
    return sorted(out, key=lambda x: x["t"])


def lyrics_enabled() -> bool:
    """要不要去 lrclib 取词。NEWAPP_LYRICS=1/0 说了算；没写就看是不是 Mele Host——Host 默认关（10-05：歌词有版权，
    别人自部署的不替他去抓）。"""
    v = os.environ.get("NEWAPP_LYRICS")
    if v is not None:
        return v == "1"
    return os.environ.get("NEWAPP_HOST", "0") != "1"


async def _httpx_get(url: str, params: dict) -> tuple[int, object]:
    async with httpx.AsyncClient(timeout=10, headers=_UA) as c:
        r = await c.get(url, params=params)
    return r.status_code, (r.json() if r.content else None)


async def lrclib(names: list[tuple[str, str]], duration_s: int, *, get=None) -> list[dict]:
    """按（歌名, 歌手）一组组试：先精确取，再搜索（时长差 3 秒以内、有带时间的词）。都没有 = []。"""
    get = get or _httpx_get
    for name, artist in names:
        if not name:
            continue
        try:
            params = {"track_name": name, "artist_name": artist}
            if duration_s:
                params["duration"] = duration_s
            status, body = await get(f"{LRCLIB}/get", params)
            if status == 200 and isinstance(body, dict) and body.get("syncedLyrics"):
                return parse_lrc(body["syncedLyrics"])
            status, body = await get(f"{LRCLIB}/search", {"track_name": name, "artist_name": artist})
            for hit in body if status == 200 and isinstance(body, list) else []:
                if not hit.get("syncedLyrics"):
                    continue
                if duration_s and abs(float(hit.get("duration") or 0) - duration_s) > 3:
                    continue
                return parse_lrc(hit["syncedLyrics"])
        except Exception as e:                                   # noqa: BLE001 —— 甜点
            log.warning("lrclib %s - %s failed: %r", name, artist, e)
    return []


# ---- 听感（Gemini 真听一遍）---------------------------------------------------------------------------

def build_prompt(name: str, artist: str, lang: str) -> str:
    if lang == "zh":
        return (f"这是这首歌的一段 30 秒试听：《{name}》— {artist}。请认真听，然后用中文写下你听到的，分四行：\n"
                "人声：谁在唱（男/女/合唱/没有人声）、嗓音的质地、唱法\n"
                "配器：听得出的乐器和音色，谁在前谁在后\n"
                "走向：情绪和能量在这段里怎么变\n"
                "歌词：用一两句话概括在讲什么（听不清就说听不清）；**不要引用歌词原文**\n\n"
                "只写听到的事实，别写乐评腔的形容词堆砌，别猜这首歌的背景故事。四行加起来 200 字以内。不要前言，不要总结。")
    return (f"This is a 30-second preview of \"{name}\" by {artist}. Listen carefully, then write what you hear in four lines:\n"
            "Voice: who's singing (male / female / group / no vocals), the texture of the voice, how it's sung\n"
            "Instruments: what you can hear, what's in front and what's behind\n"
            "Arc: how the mood and energy move in this stretch\n"
            "Lyrics: one or two sentences on what it's about (say so if you can't make it out); **don't quote the lyrics**\n\n"
            "Only facts you heard — no music-critic adjective piles, no guessing the song's backstory. Under 120 words total. "
            "No preamble, no summary.")


def clean(text: str) -> str:
    lines = [ln.strip().lstrip("-*·• ").replace("**", "") for ln in str(text or "").splitlines()]
    return "\n".join(ln for ln in lines if ln)[:IMPRESSION_MAX]


async def _httpx_post(url: str, body: dict, headers: dict) -> tuple[int, dict]:
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(url, json=body, headers=headers)
    return r.status_code, (r.json() if r.content else {})


async def gemini_impression(key: str, mp3: bytes, name: str, artist: str, lang: str, *, post=None,
                            models: list[str] | None = None) -> str:
    """把一段 mp3 交给 Gemini 听。任何失败都返回空串。"""
    if not key or not mp3:
        return ""
    post = post or _httpx_post
    models = models or MODELS
    body = {"contents": [{"parts": [
                {"inline_data": {"mime_type": "audio/mp3", "data": base64.b64encode(mp3).decode("ascii")}},
                {"text": build_prompt(name, artist, lang)}]}],
            # 不设思考档：新旧型号参数名不一样，设错整个 400（之前自用的 App踩过）
            "generationConfig": {"temperature": 0.3, "maxOutputTokens": 4000}}
    for i, model in enumerate(models):
        try:
            status, data = await post(GEMINI.format(model=model), body,
                                      {"Content-Type": "application/json", "x-goog-api-key": key})
        except Exception as e:                                   # noqa: BLE001
            log.warning("gemini ears %s failed: %r", model, e)
            return ""
        if status != 200:
            if status in _RETRYABLE and i + 1 < len(models):
                continue
            log.warning("gemini ears %s -> %s %s", model, status, str(data)[:200])
            return ""
        parts = ((data.get("candidates") or [{}])[0].get("content") or {}).get("parts") or []
        return clean("".join(p.get("text", "") for p in parts if not p.get("thought")))
    return ""


# ---- 后台听一首 ----------------------------------------------------------------------------------------

RETRY_AFTER = timedelta(hours=6)          # 失败的 6 小时后再放再试
_BUSY: set[str] = set()
_TASKS: set[asyncio.Task] = set()


class Transport:
    """联网和跑子进程的那几样，测试里换假的。"""

    async def download(self, url: str) -> bytes:
        async with httpx.AsyncClient(timeout=40, follow_redirects=True) as c:
            r = await c.get(url)
            r.raise_for_status()
            return r.content

    async def listen(self, audio: bytes) -> tuple[dict | None, bytes]:
        """m4a → (librosa 量出来的数字 / 量不出 None, 给 Gemini 的单声道 64k mp3)。librosa 在 nice 过的子进程里跑。"""
        with tempfile.TemporaryDirectory() as tmp:
            src, wav, mp3 = Path(tmp) / "a.m4a", Path(tmp) / "a.wav", Path(tmp) / "a.mp3"
            src.write_bytes(audio)
            await _run([FFMPEG, "-y", "-loglevel", "error", "-i", str(src), "-ac", "1", "-ar", "22050", str(wav)])
            await _run([FFMPEG, "-y", "-loglevel", "error", "-i", str(src), "-ac", "1", "-b:a", "64k", str(mp3)])
            nums = None
            try:
                out = await _run(["nice", "-n", "10", sys.executable, "-m", "music.ears_numbers", str(wav)],
                                 cwd=str(Path(__file__).resolve().parent.parent))
                nums = json.loads(out)
            except Exception as e:                               # noqa: BLE001
                log.warning("ears numbers failed: %r", e)
            return nums, mp3.read_bytes()

    get = staticmethod(_httpx_get)
    post = staticmethod(_httpx_post)


async def _run(cmd: list[str], cwd: str | None = None) -> str:
    p = await asyncio.create_subprocess_exec(*cmd, cwd=cwd, stdout=asyncio.subprocess.PIPE,
                                             stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(p.communicate(), timeout=180)
    except asyncio.TimeoutError:
        p.kill()
        raise
    if p.returncode:
        raise RuntimeError(f"{cmd[0]} exit {p.returncode}: {err.decode(errors='replace')[-300:]}")
    return out.decode()


def _gemini_key(deps) -> str:
    r = getattr(deps, "caption_route", None)
    return r.api_key if r is not None and r.provider == "gemini" else ""


def schedule(deps, song_id: str, storefront: str, lang: str) -> None:
    """手机报了一首在放的歌：没听过就丢后台去听，接口立刻返回。同一首同时只排一个。"""
    if not song_id or getattr(deps, "ears", None) is None or getattr(deps, "music", None) is None or song_id in _BUSY:
        return
    _BUSY.add(song_id)
    t = asyncio.create_task(_safe(deps, song_id, storefront, lang))
    _TASKS.add(t)
    t.add_done_callback(_TASKS.discard)


async def drain() -> None:
    """测试用：等后台听完。"""
    while _TASKS:
        await asyncio.gather(*list(_TASKS), return_exceptions=True)


async def _safe(deps, song_id, storefront, lang) -> None:
    try:
        await hear(deps, song_id, storefront, lang)
    except Exception:                                           # noqa: BLE001 —— 听不成不能把服务器带崩
        log.exception("ears %s", song_id)
    finally:
        _BUSY.discard(song_id)


async def hear(deps, song_id: str, storefront: str, lang: str) -> str:
    """听一首。返回做了什么：skip / impression（只补这门语言的听感）/ ok / failed。"""
    from .find import DEFAULT_STOREFRONT, alt_names

    pool, t, now = deps.pool, deps.ears, deps.now()
    key = _gemini_key(deps)
    have = await get(pool, song_id)
    if have is not None:
        if have["status"] == "failed" and now - have["heard_at"] < RETRY_AFTER:
            return "skip"
        if have["status"] == "ok" and (lang in have["impression"] or not key):
            return "skip"
    sf = storefront or DEFAULT_STOREFRONT
    found = await deps.music.songs([song_id], sf)
    s = found[0] if found else None
    audio = await t.download(s.preview) if s is not None and s.preview else b""
    if have is not None and have["status"] == "ok":              # 听过，只是没有这门语言的听感
        _, mp3 = await t.listen(audio) if audio else (None, b"")
        text = await gemini_impression(key, mp3, have["name"], have["artist"], lang, post=t.post)
        if text:
            await add_impression(pool, song_id, lang, text)
        return "impression"
    if s is None or not audio:
        await save(pool, song_id, name=s.name if s else "", artist=s.artist if s else "", duration_s=0, numbers=None,
                   impression={}, lyrics=[], lyrics_source="", status="failed", now=now)
        return "failed"
    duration = round(s.duration_ms / 1000)
    nums, mp3 = await t.listen(audio)
    text = await gemini_impression(key, mp3, s.name, s.artist, lang, post=t.post)
    names = [(s.name, s.artist)]
    alt = (await alt_names(deps.music, [song_id], sf, "zh")).get(song_id)
    if alt and (alt.name, alt.artist) not in names:
        names.append((alt.name, alt.artist))
    lyrics = await lrclib(names, duration, get=t.get) if lyrics_enabled() else []
    ok = bool(nums or text or lyrics)
    await save(pool, song_id, name=s.name, artist=s.artist, duration_s=duration, numbers=nums,
               impression={lang: text} if text else {}, lyrics=lyrics, lyrics_source="lrclib" if lyrics else "",
               status="ok" if ok else "failed", now=now)
    return "ok" if ok else "failed"


# ---- 递给 Lumi 的〔在听〕（只在 TA 说话的那一轮）---------------------------------------------------------

FULL_AGAIN = timedelta(hours=6)           # 同一首隔 6 小时再放，整段再给一次（Tilia没答，先按草稿）
MUSIC_FRESH = timedelta(minutes=20)       # 跟〔TA 那边〕的 music 一样：报了 20 分钟以上的不当现在
END_SLACK = 5                             # 位置超过时长 5 秒 = 这首已经放完了
_KEEP = 30                                # state 里最多记几首给过整段的
_T = {"zh": {"head": "〔在听〕", "song": "《{n}》", "by": "- {a}", "playing": "TA 那边在放{s}。",
             "heard": "这首你听过：{d}", "impression": "\n听到的：\n{i}", "unheard": "这首你还没听过。",
             "at": "{s}，此刻唱到：\n{lines}"},
      "en": {"head": "〔Listening〕", "song": "\"{n}\"", "by": " by {a}", "playing": "They're playing {s}. ",
             "heard": "You've heard this one: {d}", "impression": "\nWhat you heard:\n{i}", "unheard": "You haven't heard this one yet.",
             "at": "{s}, right now at:\n{lines}"}}


def _lyric_pair(lyrics: list[dict], pos: float) -> list[str]:
    """唱到的那句和它前一句；还没到第一句 = []。"""
    idx = -1
    for i, x in enumerate(lyrics):
        if x["t"] <= pos:
            idx = i
        else:
            break
    if idx < 0:
        return []
    return [lyrics[idx - 1]["line"], lyrics[idx]["line"]] if idx > 0 else [lyrics[idx]["line"]]


def line(song: dict | None, music: dict | None, at: datetime | None, now: datetime, state: dict, lang: str) -> str:
    """这一轮给不给〔在听〕、给什么。state 里记：ears_full {song: 上次给整段的时间}、ears_unheard（说过没听过的那首）。"""
    if not music or not music.get("playing") or at is None or now - at > MUSIC_FRESH:
        return ""
    w = _T["zh" if lang == "zh" else "en"]
    sid = str(music.get("song_id") or "") or f"name:{music.get('name', '')}"
    title = w["song"].format(n=music.get("name", "")) + (w["by"].format(a=music["artist"]) if music.get("artist") else "")
    heard = song is not None and song.get("status") == "ok"
    full: dict = state.get("ears_full") or {}
    last = full.get(sid)
    if heard and (last is None or now - datetime.fromisoformat(last) >= FULL_AGAIN):
        full[sid] = now.isoformat()
        state["ears_full"] = dict(sorted(full.items(), key=lambda kv: kv[1])[-_KEEP:])
        from .ears_numbers import describe
        body = w["playing"].format(s=title)
        if song.get("numbers"):
            body += w["heard"].format(d=describe(song["numbers"], lang))
        imp = (song.get("impression") or {}).get(lang) or next(iter((song.get("impression") or {}).values()), "")
        if imp:
            body += w["impression"].format(i=imp)
        return w["head"] + body.rstrip()
    if not heard:
        if state.get("ears_unheard") == sid:
            return ""
        state["ears_unheard"] = sid
        return w["head"] + w["playing"].format(s=title) + w["unheard"]
    lyrics, pos = song.get("lyrics") or [], music.get("position_s")
    if not lyrics or not isinstance(pos, (int, float)):
        return ""
    pos = float(pos) + (now - at).total_seconds()
    if song.get("duration_s") and pos > song["duration_s"] + END_SLACK:
        return ""
    pair = _lyric_pair(lyrics, pos)
    return w["head"] + w["at"].format(s=w["song"].format(n=music.get("name", "")), lines="\n".join(pair)) if pair else ""


async def for_turn(pool, items: dict, state: dict, now: datetime, lang: str) -> str:
    """大脑用：从〔TA 那边〕存的 music 拼〔在听〕。"""
    music, at = items.get("music") or (None, None)
    if not music or not music.get("playing"):
        return ""
    song = await get(pool, music["song_id"]) if music.get("song_id") else None
    return line(song, music, at, now, state, lang)
