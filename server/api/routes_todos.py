"""待办和常去的地方的接口（10-01）。手机的地理围栏进出也报到这里（/places/{id}/event）。"""
from __future__ import annotations

from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import accounts, archive
from brain import todos as T
from brain.persona import Persona
from brain.settings import Settings

from .deps import Api, account, api

router = APIRouter()


async def _main(pool, acc: UUID) -> UUID:
    comps = await accounts.list_companions(pool, acc)
    if not comps:
        raise HTTPException(409, "还没有联系人")
    return comps[0]


async def _render(a: Api, acc: UUID, todos: list[T.Todo]) -> list[dict]:
    pool, now = a.deps.pool, a.deps.now()
    places = {p.id: p for p in await T.list_places(pool, acc)}
    names: dict[UUID, str] = {}
    settings: dict[UUID, Settings] = {}
    out = []
    for t in todos:
        cid = t.companion_id
        if cid not in settings:
            settings[cid] = Settings.from_dict(await archive.get_settings(pool, cid))
            names[cid] = Persona.from_dict(await archive.get_persona(pool, cid)).name
        s = settings[cid]
        out.append(T.to_dict(t, now.astimezone(ZoneInfo(s.tz)).date(), s.tz, places, names, s.lang))
    return out


def _bad(e: Exception) -> HTTPException:
    return HTTPException(400, str(e))


def _cid(body: dict) -> UUID | None:
    v = body.get("companion_id")
    try:
        return UUID(str(v)) if v else None
    except ValueError:
        raise HTTPException(400, "companion_id 不对")


@router.get("/todos")
async def list_todos(acc: UUID = Depends(account), a: Api = Depends(api)):
    pool = a.deps.pool
    rows = await _render(a, acc, await T.list_all(pool, acc))
    return sorted(rows, key=lambda r: r["done"])          # 没做完的在前，各自按写的先后


@router.post("/todos", status_code=201)
async def add_todo(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{what, shape?: once|at, spec?, place_id?, place_on?: arrive|leave, companion_id?（谁来提醒，默认主联系人）}"""
    pool = a.deps.pool
    try:
        t = await T.create(pool, acc, _cid(body) or await _main(pool, acc), what=str(body.get("what") or ""),
                           shape=body.get("shape") or None, spec=body.get("spec") or None,
                           place_id=body.get("place_id"), place_on=body.get("place_on"), now=a.deps.now())
    except PermissionError:
        raise HTTPException(404, "没有这个联系人")
    except (ValueError, TypeError, KeyError) as e:
        raise _bad(e) from e
    return (await _render(a, acc, [t]))[0]


@router.patch("/todos/{todo_id}")
async def patch_todo(todo_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    pool = a.deps.pool
    kw = {k: body[k] or None for k in ("what", "shape", "spec", "place_id", "place_on") if k in body}
    if "what" in kw:
        kw["what"] = body["what"] or ""
    if "companion_id" in body:
        kw["companion"] = _cid(body)
    try:
        t = await T.update(pool, acc, todo_id, now=a.deps.now(), **kw)
    except LookupError:
        raise HTTPException(404, "没有这条待办")
    except PermissionError:
        raise HTTPException(404, "没有这个联系人")
    except (ValueError, TypeError, KeyError) as e:
        raise _bad(e) from e
    return (await _render(a, acc, [t]))[0]


@router.post("/todos/{todo_id}/done")
async def done_todo(todo_id: int, body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{done: true|false}：打勾 = 这一期做完了（一次性 = 做完；每天 = 今天；每周 = 这周）。"""
    try:
        t = await T.set_done(a.deps.pool, acc, todo_id, bool(body.get("done", True)), a.deps.now())
    except LookupError:
        raise HTTPException(404, "没有这条待办")
    return (await _render(a, acc, [t]))[0]


@router.delete("/todos/{todo_id}", status_code=204)
async def delete_todo(todo_id: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await T.delete(a.deps.pool, acc, todo_id):
        raise HTTPException(404, "没有这条待办")
    return Response(status_code=204)


@router.get("/places")
async def list_places(acc: UUID = Depends(account), a: Api = Depends(api)):
    return [p.to_dict() for p in await T.list_places(a.deps.pool, acc)]


@router.post("/places", status_code=201)
async def add_place(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{name, lat, lon, radius?（米，100～1000，默认 150）}"""
    try:
        p = await T.add_place(a.deps.pool, acc, name=str(body.get("name") or ""), lat=body.get("lat"),
                              lon=body.get("lon"), radius=body.get("radius") or 150)
    except (ValueError, TypeError) as e:
        raise _bad(e) from e
    return p.to_dict()


@router.patch("/places/{place_id}")
async def patch_place(place_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        p = await T.update_place(a.deps.pool, acc, place_id, **{k: body[k] for k in ("name", "lat", "lon", "radius")
                                                                 if k in body})
    except LookupError:
        raise HTTPException(404, "没有这个地方")
    except (ValueError, TypeError) as e:
        raise _bad(e) from e
    return p.to_dict()


@router.delete("/places/{place_id}", status_code=204)
async def delete_place(place_id: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await T.delete_place(a.deps.pool, acc, place_id):
        raise HTTPException(404, "没有这个地方")
    return Response(status_code=204)


@router.post("/places/{place_id}/event")
async def place_event(place_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """手机的地理围栏：{inside: true = 进来了 / false = 出去了, sync?: true = 只是对一下现在在不在}。只报进出哪个存过的地方，不报位置。"""
    if "inside" not in body:
        raise HTTPException(400, "要说进来了还是出去了")
    try:
        fired = await T.place_event(a.deps.pool, acc, place_id, bool(body["inside"]), a.deps.now(),
                                    sync=bool(body.get("sync")))
    except LookupError:
        raise HTTPException(404, "没有这个地方")
    return {"reminding": fired}
