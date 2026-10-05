"""书架的接口（10-02）：书（导入 / 列表 / 改名 / 封面 / 删）、章、页边、阅读打点。"""
from __future__ import annotations

from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse

from brain import accounts, archive
from brain import books as BK
from brain.settings import Settings

from .deps import Api, account, api, own_companion

router = APIRouter()


async def _today(a: Api, acc: UUID):
    comps = await accounts.list_companions(a.deps.pool, acc)
    tz = Settings.from_dict(await archive.get_settings(a.deps.pool, comps[0])).tz if comps else "UTC"
    return a.deps.now().astimezone(ZoneInfo(tz)).date()


async def _book(a: Api, acc: UUID, bid: int) -> BK.Book:
    b = await BK.get(a.deps.pool, acc, bid)
    if b is None:
        raise HTTPException(404, "没有这本书")
    return b


@router.get("/books")
async def list_books(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await BK.list_all(a.deps.pool, acc, await _today(a, acc))


@router.post("/books", status_code=201)
async def add(file: UploadFile = File(...), title: str = Form(""), acc: UUID = Depends(account), a: Api = Depends(api)):
    data = await file.read(BK.MAX_BYTES + 1)
    try:
        b = await BK.add(a.deps.pool, a.cfg.files_dir, acc, name=file.filename or "", data=data, title=title,
                         now=a.deps.now())
    except BK.BookError as e:
        raise HTTPException(400, str(e)) from e
    return b.public()


@router.patch("/books/{bid}")
async def rename(bid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        b = await BK.rename(a.deps.pool, acc, bid, str(body.get("title") or ""))
    except BK.BookError as e:
        raise HTTPException(400, str(e)) from e
    if b is None:
        raise HTTPException(404, "没有这本书")
    return b.public()


@router.delete("/books/{bid}", status_code=204)
async def delete(bid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await BK.delete(a.deps.pool, acc, bid):
        raise HTTPException(404, "没有这本书")
    return Response(status_code=204)


@router.put("/books/{bid}/cover", status_code=204)
async def cover(bid: int, file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        ok = await BK.set_cover(a.deps.pool, acc, bid, a.cfg.files_dir, await file.read())
    except Exception as e:
        raise HTTPException(400, "这张图打不开") from e
    if not ok:
        raise HTTPException(404, "没有这本书")
    return Response(status_code=204)


@router.get("/books/{bid}/cover")
async def get_cover(bid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    b = await _book(a, acc, bid)
    if not b.cover_path:
        raise HTTPException(404, "没有封面")
    return FileResponse(b.cover_path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})


@router.get("/books/{bid}/chapters")
async def chapters(bid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    b = await _book(a, acc, bid)
    return [{"index": i, "title": c[0], "length": c[2] - c[1]} for i, c in enumerate(b.chapters)]


@router.get("/books/{bid}/chapters/{i}")
async def chapter(bid: int, i: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    b = await _book(a, acc, bid)
    try:
        return {"index": i, "title": b.chapters[i][0] if 0 <= i < len(b.chapters) else "", "text": BK.chapter_text(b, i)}
    except BK.BookError as e:
        raise HTTPException(404, str(e)) from e


@router.get("/books/{bid}/marks")
async def marks(bid: int, chapter: int | None = None, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _book(a, acc, bid)
    return await BK.marks(a.deps.pool, acc, bid, chapter)


@router.post("/books/{bid}/marks", status_code=201)
async def add_mark(bid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{chapter, quote, note?, pos?, parent_id?, companion_id?}——TA 划线 / 批注 / 在线头底下回一句。
    「划线说两句」：先在这儿建线头（带 companion_id），再把那句带着 book_mark_id 发进那个联系人的窗口。"""
    comp = UUID(str(body["companion_id"])) if body.get("companion_id") else None
    if comp:
        await own_companion(a, acc, comp)
    try:
        return await BK.add_mark(a.deps.pool, acc, bid, chapter=int(body.get("chapter") or 0),
                                 quote=str(body.get("quote") or ""), note=str(body.get("note") or ""), author="user",
                                 pos=int(body.get("pos") if body.get("pos") is not None else -1), companion=comp,
                                 parent=int(body["parent_id"]) if body.get("parent_id") else None, now=a.deps.now())
    except (BK.BookError, ValueError) as e:
        raise HTTPException(400, str(e)) from e


@router.delete("/books/{bid}/marks/{mid}", status_code=204)
async def delete_mark(bid: int, mid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await BK.delete_mark(a.deps.pool, acc, bid, mid):
        raise HTTPException(404, "没有这条（它写的删不了）")
    return Response(status_code=204)


@router.post("/books/{bid}/reading", status_code=204)
async def reading(bid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{chapter, page, page_count, seconds}：翻页报一声（seconds=0），开着每分钟报一声（seconds=60）"""
    ok = await BK.report(a.deps.pool, acc, bid, chapter=int(body.get("chapter") or 0), page=int(body.get("page") or 0),
                         page_count=int(body.get("page_count") or 0), seconds=int(body.get("seconds") or 0),
                         today=await _today(a, acc), now=a.deps.now())
    if not ok:
        raise HTTPException(404, "没有这本书")
    return Response(status_code=204)
