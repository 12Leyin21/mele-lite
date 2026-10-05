"""音乐的接口（09-30，音乐第 4 步）：连接 Apple Music、歌单、每日私选投票、手机报在听、查一首歌补全歌卡。"""
from __future__ import annotations

from datetime import date
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import accounts, archive, context_line
from food.store import today
from music import daily, ears, find
from music import store as S

from .deps import Api, account, api

router = APIRouter()


def _day(v) -> date | None:
    if not v:
        return None
    try:
        return date.fromisoformat(str(v))
    except ValueError:
        raise HTTPException(400, "日期要写成 YYYY-MM-DD") from None


async def _lang(pool, acc: UUID) -> str:
    comps = await accounts.list_companions(pool, acc)
    return (await archive.get_settings(pool, comps[0])).get("lang") or "zh" if comps else "zh"


def _view(link) -> dict:
    if link is None:
        return {"platform": None, "linked": False, "storefront": "", "picks_n": 0, "picks_at": "", "lyrics": False}
    return {"platform": link.platform, "linked": bool(link.user_token), "storefront": link.storefront,
            "picks_n": link.picks_n, "picks_at": link.picks_at, "lyrics": link.lyrics}


@router.get("/me/music")
async def get_music(acc: UUID = Depends(account), a: Api = Depends(api)):
    return _view(await S.get_link(a.deps.pool, a.cfg.box, acc))


@router.put("/me/music")
async def put_music(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{platform, user_token?}：选 Apple Music 并给了用户凭证，先拿它问一次「你在哪个区」，问得通才算连上。"""
    platform = str(body.get("platform") or "")
    if platform not in S.PLATFORMS:
        raise HTTPException(400, "不认识这个听歌平台")
    token = str(body.get("user_token") or "").strip() or None
    # 没凭证（比如没有 Apple Music 会员，09-30）：手机自己知道在哪个区，报上来给私选找歌用；有凭证的以苹果回的为准
    storefront = str(body.get("storefront") or "").strip().lower()
    storefront = storefront if len(storefront) == 2 and storefront.isalpha() else ""
    if platform == "apple" and token and getattr(a.deps.music, "user_features", True):   # iTunes 找歌（Host）没有凭证那一套
        if a.deps.music is None:
            raise HTTPException(503, "服务器还没配 Apple Music，过一阵再连")
        storefront = await a.deps.music.storefront(token)
        if not storefront:
            raise HTTPException(400, "Apple Music 没连上，再试一次")
    await S.link(a.deps.pool, a.cfg.box, acc, platform=platform, user_token=token, storefront=storefront)
    await daily.ensure_clock(a.deps.pool, acc, a.deps.now())       # 选了平台就开每日私选的钟
    return _view(await S.get_link(a.deps.pool, a.cfg.box, acc))


@router.patch("/me/music")
async def patch_music(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{picks_n?: 0~5（0 = 不推）, picks_at?: "HH:MM" 或 ""（空 = 起床后半小时）}"""
    pool = a.deps.pool
    if await pool.fetchval("SELECT 1 FROM music_links WHERE account_id = $1", acc) is None:
        raise HTTPException(400, "先选你用什么听歌")
    if "picks_n" in body:
        n = int(body["picks_n"])
        if not 0 <= n <= 5:
            raise HTTPException(400, "每天 0~5 首")
        await pool.execute("UPDATE music_links SET picks_n = $2 WHERE account_id = $1", acc, n)
    if "lyrics" in body:                     # Host 的歌词开关（10-05）：只管以后新听的歌
        await pool.execute("UPDATE music_links SET lyrics = $2 WHERE account_id = $1", acc, bool(body["lyrics"]))
    if "picks_at" in body:
        at = str(body["picks_at"] or "")
        if at:
            try:
                h, m = (int(x) for x in at.split(":"))
                assert 0 <= h < 24 and 0 <= m < 60
            except (ValueError, AssertionError):
                raise HTTPException(400, "时间写成 HH:MM") from None
        await pool.execute("UPDATE music_links SET picks_at = $2 WHERE account_id = $1", acc, at)
    await daily.ensure_clock(pool, acc, a.deps.now())
    return _view(await S.get_link(pool, a.cfg.box, acc))


@router.delete("/me/music", status_code=204)
async def delete_music(acc: UUID = Depends(account), a: Api = Depends(api)):
    await S.unlink(a.deps.pool, acc)
    await daily.ensure_clock(a.deps.pool, acc, a.deps.now())       # 没平台了：钟删掉
    return Response(status_code=204)


@router.get("/music/shelf")
async def shelf(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await S.shelf(a.deps.pool, acc)


@router.get("/music/picks")
async def picks(day: str = "", acc: UUID = Depends(account), a: Api = Depends(api)):
    d = _day(day) or await today(a.deps.pool, acc, a.deps.now())
    return await S.picks_on(a.deps.pool, acc, d)


@router.post("/music/picks/{day}/{pos}/vote")
async def vote(day: str, pos: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{vote: up / meh / down / 空, stars?: 0~5, reason?}"""
    got = await S.vote(a.deps.pool, acc, _day(day), pos, str(body.get("vote") or ""),
                       stars=body.get("stars"), reason=body.get("reason"))
    if got is None:
        raise HTTPException(404, "没有这一首")
    return got


@router.post("/music/now", status_code=204)
async def now_playing(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """手机报在听什么：{song_id?, name, artist, playing, position_s?}（一起听页开着 / 回前台 / 发消息前）。进〔TA 那边〕，变了才给它。
    position_s = 放到第几秒（耳朵按它 + 过去的秒数算唱到哪）；在放、没听过的歌丢后台去听（09-30 耳朵）。"""
    name = str(body.get("name") or "").strip()[:200]
    if not name:
        raise HTTPException(400, "歌名是空的")
    data = {"song_id": str(body.get("song_id") or ""), "name": name,
            "artist": str(body.get("artist") or "").strip()[:200], "playing": bool(body.get("playing"))}
    pos = body.get("position_s")
    if isinstance(pos, (int, float)) and not isinstance(pos, bool) and 0 <= pos < 36_000:
        data["position_s"] = round(float(pos), 1)
    pool = a.deps.pool
    await context_line.save(pool, acc, "music", data, a.deps.now())
    if data["playing"] and data["song_id"]:
        ears.schedule(a.deps, data["song_id"], await S.storefront_of(pool, acc), await _lang(pool, acc))
    return Response(status_code=204)


@router.get("/music/song/{song_id}")
async def song(song_id: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    """歌卡补全：封面、试听、链接用 TA 那个区的；名字按 TA 的语言。"""
    if a.deps.music is None:
        raise HTTPException(503, "服务器还没配 Apple Music")
    link = await S.get_link(a.deps.pool, a.cfg.box, acc)
    sf = (link.storefront if link else "") or find.DEFAULT_STOREFRONT
    got = await a.deps.music.songs([song_id], sf)
    if not got:
        raise HTTPException(404, "曲库里没有这首")
    alt = await find.alt_names(a.deps.music, [song_id], sf, await _lang(a.deps.pool, acc))
    return find.shown(got[0], alt.get(song_id))
