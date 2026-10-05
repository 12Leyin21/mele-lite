"""照片和文件（iOS 第一块第 3 步）。借 test_api 的 Env；测试用小满。"""
import io
from pathlib import Path
from uuid import UUID

from PIL import Image

from test_api import Env

def make_pdf(text: str) -> bytes:
    """最小的一页 PDF（带目录表，pypdf 读得出字）。"""
    stream = f"BT /F1 12 Tf 20 100 Td ({text}) Tj ET".encode()
    objs = [b"<</Type/Catalog/Pages 2 0 R>>", b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
            b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>",
            b"<</Length %d>>stream\n" % len(stream) + stream + b"\nendstream",
            b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj" % i + o + b"endobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % off for off in offsets)
    out += b"trailer<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return bytes(out)


PDF = make_pdf("Hello Xiaoman")


def png(w=3000, h=1000) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (w, h), (200, 120, 90)).save(out, "PNG")
    return out.getvalue()


async def setup(pool, tmp_path, script=()):
    e = Env(pool, script)
    e.app.state.api.cfg.files_dir = tmp_path
    t = await e.login()
    return e, t


async def open_window(e, c):
    comp, conv = await e.first_window(c)
    await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
    return conv["id"]


async def test_image_upload_shrinks_and_only_owner_can_fetch(pool, tmp_path):
    e, t = await setup(pool, tmp_path)
    async with e.client(t) as c:
        conv = await open_window(e, c)
        r = await c.post(f"/conversations/{conv}/attachments", files={"file": ("sea.png", png(), "image/png")})
        assert r.status_code == 201 and r.json()["kind"] == "image" and r.json()["mime"] == "image/jpeg"
        got = await c.get(f"/attachments/{r.json()['id']}")
        assert got.content[:2] == b"\xff\xd8" and max(Image.open(io.BytesIO(got.content)).size) == 2048
    other = await e.login("mia@example.com")
    async with e.client(other) as c:
        assert (await c.get(f"/attachments/{r.json()['id']}")).status_code == 404
        assert (await c.post(f"/conversations/{conv}/attachments",
                             files={"file": ("a.txt", b"hi", "text/plain")})).status_code == 404


async def test_file_text_reaches_it_and_stays_in_history(pool, tmp_path):
    e, t = await setup(pool, tmp_path, ["看到了", "嗯"])
    async with e.client(t) as c:
        conv = await open_window(e, c)
        txt = (await c.post(f"/conversations/{conv}/attachments",
                            files={"file": ("清单.md", "# 周末\n- 买燕麦奶\n- 约 Mia 看展".encode(), "text/markdown")})).json()
        pdf = (await c.post(f"/conversations/{conv}/attachments",
                            files={"file": ("课表.pdf", PDF, "application/pdf")})).json()
        await c.post(f"/conversations/{conv}/messages", json={"text": "帮我看看", "attachments": [txt["id"], pdf["id"]]})
        await e.rooms.idle(UUID(conv))
        await c.post(f"/conversations/{conv}/messages", json={"text": "好"})
        await e.rooms.idle(UUID(conv))
        listed = (await c.get(f"/conversations/{conv}/messages")).json()["messages"]
    first = e.model.requests[0].messages[-1].text
    assert "帮我看看" in first and "〔TA 发了文件「清单.md」，内容：\n# 周末" in first and "Hello Xiaoman" in first
    assert "约 Mia 看展" in e.model.requests[1].messages[0].text                      # 下一轮历史里还在
    assert [a["name"] for a in listed[0]["attachments"]] == ["清单.md", "课表.pdf"] and listed[0]["text"] == "帮我看看"


async def test_photo_only_message_and_bad_types(pool, tmp_path):
    e, t = await setup(pool, tmp_path, ["好看"])
    async with e.client(t) as c:
        conv = await open_window(e, c)
        img = (await c.post(f"/conversations/{conv}/attachments", files={"file": ("a.png", png(40, 40), "image/png")})).json()
        assert (await c.post(f"/conversations/{conv}/messages", json={"attachments": [img["id"]]})).status_code == 202
        await e.rooms.idle(UUID(conv))
        bad = await c.post(f"/conversations/{conv}/attachments", files={"file": ("x.exe", b"MZ", "application/octet-stream")})
        assert bad.status_code == 400 and "先只认" in bad.json()["detail"]
        assert (await c.post(f"/conversations/{conv}/messages", json={"text": ""})).status_code == 400
    assert "〔TA 发了一张图片" in e.model.requests[0].messages[-1].text


async def test_files_go_away_with_window_and_rewind(pool, tmp_path):
    e, t = await setup(pool, tmp_path, ["收到"])
    async with e.client(t) as c:
        conv = await open_window(e, c)
        a = (await c.post(f"/conversations/{conv}/attachments", files={"file": ("a.txt", b"hello", "text/plain")})).json()
        await c.post(f"/conversations/{conv}/messages", json={"text": "看", "attachments": [a["id"]]})
        await e.rooms.idle(UUID(conv))
        user = (await c.get(f"/conversations/{conv}/messages")).json()["messages"][0]
        assert len(list(Path(tmp_path).iterdir())) == 1
        assert (await c.post(f"/conversations/{conv}/rewind", json={"message_id": user["id"]})).json()["kind"] == "edit"
        assert list(Path(tmp_path).iterdir()) == []
        b = (await c.post(f"/conversations/{conv}/attachments", files={"file": ("b.txt", b"x", "text/plain")})).json()
        assert b and len(list(Path(tmp_path).iterdir())) == 1
        inco = (await c.post(f"/companions/{(await e.first_window(c))[0]['id']}/conversations", json={})).json()
        assert (await c.delete(f"/conversations/{conv}")).status_code == 204
        assert list(Path(tmp_path).iterdir()) == [] and inco
