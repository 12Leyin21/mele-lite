"""表情包第 2 步：收（不重复、上限、格式、动图原样）、看过的图直接用描述、改名字 / 描述 / 只给谁、搜、删、后台写描述。测试用小满。"""
import io
from datetime import datetime, timezone

import pytest
from PIL import Image

from brain import accounts, archive
from brain import stickers as S
from llm.fake import FakeModel
from llm.router import Route
from memory.embed import FakeEmbedder
from test_api import Env

E = FakeEmbedder()
NOW = datetime(2026, 10, 1, 12, tzinfo=timezone.utc)


def pic(color=(200, 80, 120), fmt="PNG", frames=1) -> bytes:
    out = io.BytesIO()
    ims = [Image.new("RGB", (48, 48), (color[0], color[1], (color[2] + 40 * i) % 255)) for i in range(frames)]
    if frames > 1:
        ims[0].save(out, fmt, save_all=True, append_images=ims[1:], duration=100, loop=0)
    else:
        ims[0].save(out, fmt)
    return out.getvalue()


async def people(pool):
    acc = await accounts.create_account(pool)
    a = await accounts.create_companion(pool, acc)
    b = await accounts.create_companion(pool, acc)
    return acc, a, b


async def test_add_dedupe_formats_and_limits(pool, tmp_path):
    acc, _, _ = await people(pool)
    s, new = await S.add(pool, E, tmp_path, acc, data=pic(), name="得意")
    assert new and s.mime == "image/png" and s.name == "得意"
    again, new2 = await S.add(pool, E, tmp_path, acc, data=pic())
    assert not new2 and again.id == s.id                                          # 同一张不重复收
    gif, _ = await S.add(pool, E, tmp_path, acc, data=pic((1, 2, 3), "GIF", frames=3))
    assert gif.mime == "image/gif" and open(gif.path, "rb").read()[:3] == b"GIF"  # 动图原样存
    with pytest.raises(S.StickerError):
        await S.add(pool, E, tmp_path, acc, data=b"not an image")
    with pytest.raises(S.StickerError):
        await S.add(pool, E, tmp_path, acc, data=pic(fmt="BMP"))
    await pool.execute("UPDATE stickers SET sha = 'x' || id WHERE account_id = $1", acc)
    for i in range(S.MAX_STICKERS - 2):
        await pool.execute("INSERT INTO stickers (account_id, sha, path, mime, size) VALUES ($1, $2, '/x', 'image/png', 1)",
                           acc, f"fill{i}")
    with pytest.raises(S.StickerError):
        await S.add(pool, E, tmp_path, acc, data=pic((9, 9, 9)))


async def test_seen_photo_brings_its_caption(pool, tmp_path):
    acc, _, _ = await people(pool)
    import hashlib
    data = pic((5, 5, 5))
    await pool.execute("INSERT INTO image_captions (account_id, sha, lang, caption) VALUES ($1, $2, 'zh', '一只翻白眼的猫')",
                       acc, hashlib.sha256(data).hexdigest())
    s, _ = await S.add(pool, E, tmp_path, acc, data=data)
    assert s.caption == "一只翻白眼的猫"


async def test_edit_only_for_search_delete(pool, tmp_path):
    acc, lumi, lin = await people(pool)
    smug, _ = await S.add(pool, E, tmp_path, acc, data=pic((1, 1, 1)), caption="一只叉腰的猫，很得意")
    sad, _ = await S.add(pool, E, tmp_path, acc, data=pic((2, 2, 2)), caption="小狗趴着哭，委屈巴巴")
    blank, _ = await S.add(pool, E, tmp_path, acc, data=pic((3, 3, 3)))
    assert [x.id for x in await S.search(pool, E, acc, lumi, "得意")][0] == smug.id
    assert blank.id not in [x.id for x in await S.search(pool, E, acc, lumi, "猫")]          # 没描述的搜不到
    await S.update(pool, E, acc, sad.id, only_for=[lin])
    assert sad.id not in [x.id for x in await S.search(pool, E, acc, lumi, "委屈")]           # 只给林晚
    assert [x.id for x in await S.search(pool, E, acc, lin, "委屈")][0] == sad.id
    assert await S.usable(pool, acc, lumi, sad.id) is None and await S.usable(pool, acc, lin, sad.id)
    other = await accounts.create_account(pool)
    with pytest.raises(S.StickerError):
        await S.update(pool, E, acc, sad.id, only_for=[await accounts.create_companion(pool, other)])
    got = await S.update(pool, E, acc, smug.id, caption="阴阳怪气地笑", name="阴阳")
    assert (got.caption, got.name) == ("阴阳怪气地笑", "阴阳")
    assert [x.id for x in await S.search(pool, E, acc, lumi, "阴阳")][0] == smug.id
    assert await S.get(pool, other, smug.id) is None
    path = smug.path
    assert await S.delete(pool, acc, smug.id) and not __import__("os").path.exists(path)


async def test_caption_pending_uses_a_seeing_model(pool, tmp_path):
    e = Env(pool, [])
    eye = FakeModel(["一只小熊比心，适合撒娇的时候发。"])
    e.deps.caption_route = Route("gemini", "ours-caption", "gemini-flash", "gemini-flash")
    chat = e.deps.adapter_for
    e.deps.adapter_for = lambda r: eye if r.provider == "gemini" else chat(r)
    await e.login()
    acc = await pool.fetchval("SELECT id FROM accounts")
    s, _ = await S.add(pool, e.deps.embedder, tmp_path, acc, data=pic((7, 7, 7), "GIF", frames=2))
    assert await S.caption_pending(e.deps, acc, NOW) == 1
    assert (await S.get(pool, acc, s.id)).caption.startswith("一只小熊比心")
    assert eye.requests[0].messages[0].images[0].mime == "image/png"                  # 动图给第一帧
    assert "表情包" in eye.requests[0].messages[0].text
    assert await pool.fetchval("SELECT caption FROM image_captions WHERE sha = $1", s.sha)    # 指纹也记一份
