"""iOS 第二块第 2 步：窗口名、头像、关系、traits、同步高级设置。借 test_api 的 Env；测试用小满。"""
import io
import json
from datetime import datetime, timedelta, timezone
from uuid import UUID

from PIL import Image

from brain import archive, traits
from test_api import Env

T0 = datetime(2026, 9, 28, 4, 0, tzinfo=timezone.utc)


def jpg(w=900, h=600) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (w, h), (90, 120, 200)).save(out, "JPEG")
    return out.getvalue()


async def setup(pool, tmp_path=None):
    e = Env(pool)
    if tmp_path is not None:
        e.app.state.api.cfg.files_dir = tmp_path
    t = await e.login()
    return e, t


async def test_window_title_and_first_line(pool):
    e, t = await setup(pool)
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = UUID(conv["id"])
        now = datetime.now(timezone.utc)            # 「最近 7 天」按真实时钟算
        await archive.add_message(pool, cid, "user", "我们来计划一下去墨尔本的行程吧", now=now)
        await archive.add_message(pool, cid, "assistant", "好呀", now=now)
        assert (await c.get("/companions")).json()[0]["week_messages"] == 2
        old = now - timedelta(days=30)
        await archive.add_message(pool, cid, "user", "很久以前的一句", now=old)
        listed = (await c.get("/companions")).json()[0]
        assert listed["week_messages"] == 2 and listed["total_messages"] == 3   # 认识第几天中号：一共聊了几条（10-04）
        row = (await c.get(f"/companions/{comp['id']}/conversations")).json()[0]
        assert row["title"] == "" and row["first"] == "我们来计划一下去墨尔本的行程吧"[:20]
        r = await c.patch(f"/conversations/{cid}", json={"title": "  墨尔本旅行  "})
        assert r.status_code == 200 and r.json()["title"] == "墨尔本旅行"
        assert (await c.patch(f"/conversations/{cid}", json={"title": "长" * 31})).status_code == 400
        r = await c.patch(f"/conversations/{cid}", json={"title": ""})
        assert r.json()["title"] == ""


async def test_window_title_other_account_404(pool):
    e, t = await setup(pool)
    t2 = await e.login("mia@example.com")
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
    async with e.client(t2) as c2:
        assert (await c2.patch(f"/conversations/{conv['id']}", json={"title": "x"})).status_code == 404


async def test_avatar_upload_get_delete(pool, tmp_path):
    e, t = await setup(pool, tmp_path)
    t2 = await e.login("mia@example.com")
    async with e.client(t) as c:
        comp = (await c.get("/companions")).json()[0]
        assert comp["avatar_ver"] == 0 and comp["created_at"]
        assert (await c.get(f"/companions/{comp['id']}/avatar")).status_code == 404
        r = await c.put(f"/companions/{comp['id']}/avatar", files={"file": ("a.jpg", jpg(), "image/jpeg")})
        assert r.status_code == 200 and r.json()["avatar_ver"] == 1
        img = await c.get(f"/companions/{comp['id']}/avatar")
        assert img.status_code == 200 and img.headers["content-type"] == "image/jpeg"
        assert Image.open(io.BytesIO(img.content)).size == (512, 512)
        async with e.client(t2) as c2:
            assert (await c2.get(f"/companions/{comp['id']}/avatar")).status_code == 404
        r = await c.delete(f"/companions/{comp['id']}/avatar")
        assert r.status_code == 200 and r.json()["avatar_ver"] == 2
        assert (await c.get(f"/companions/{comp['id']}/avatar")).status_code == 404
        bad = await c.put(f"/companions/{comp['id']}/avatar", files={"file": ("a.txt", b"not an image", "text/plain")})
        assert bad.status_code == 400


async def test_avatar_file_removed_with_companion(pool, tmp_path):
    e, t = await setup(pool, tmp_path)
    async with e.client(t) as c:
        other = (await c.post("/companions", json={"name": "小满的朋友"})).json()
        await c.put(f"/companions/{other['id']}/avatar", files={"file": ("a.jpg", jpg(), "image/jpeg")})
        assert (tmp_path / "avatars" / f"{other['id']}.jpg").exists()
        assert (await c.delete(f"/companions/{other['id']}")).status_code == 204
        assert not (tmp_path / "avatars" / f"{other['id']}.jpg").exists()


async def test_relationship_setting(pool):
    e, t = await setup(pool)
    async with e.client(t) as c:
        comp = (await c.get("/companions")).json()[0]
        r = await c.patch(f"/companions/{comp['id']}", json={"settings": {"relationship": "friend"}})
        assert r.json()["settings"]["relationship"] == "friend"
        r = await c.patch(f"/companions/{comp['id']}", json={"settings": {"relationship": "  饭搭子  "}})
        assert r.json()["settings"]["relationship"] == "饭搭子"
        r = await c.patch(f"/companions/{comp['id']}", json={"settings": {"relationship": "长" * 21}})
        assert r.status_code == 400


async def test_traits_empty_catalog(pool, monkeypatch):
    e, t = await setup(pool)
    async with e.client(t) as c:
        comp = (await c.get("/companions")).json()[0]
        assert (await c.get("/traits")).json() == []
        assert (await c.patch(f"/companions/{comp['id']}", json={"persona": {"traits": ["cheerful"]}})).status_code == 400
        r = await c.patch(f"/companions/{comp['id']}", json={"persona": {"traits": []}})
        assert r.status_code == 200 and r.json()["persona"]["traits"] == []


async def test_traits_render_into_base(pool, monkeypatch):
    monkeypatch.setattr(traits, "TRAITS", {
        "bookworm": {"name": {"zh": "书虫", "en": "Bookworm"}, "desc": {"zh": "爱看书", "en": "Loves books"},
                     "line": {"zh": "我爱看书，聊着聊着会提到最近读的。", "en": "I love books and bring up what I'm reading."}}})
    e, t = await setup(pool)
    async with e.client(t) as c:
        comp = (await c.get("/companions")).json()[0]
        assert (await c.get("/traits")).json() == [{"id": "bookworm", "name": "书虫", "desc": "爱看书"}]
        r = await c.patch(f"/companions/{comp['id']}", json={"persona": {"traits": ["bookworm"]}})
        assert r.status_code == 200
        too_many = await c.patch(f"/companions/{comp['id']}", json={"persona": {"traits": ["bookworm"] * 4}})
        assert too_many.status_code == 400
    from brain.persona import Persona, render_base
    p = Persona.from_dict({"traits": ["bookworm"]}, "zh")
    assert "我爱看书，聊着聊着会提到最近读的。" in render_base(p, [], "zh")


async def test_sync_advanced_copies_only_inner_layer(pool):
    e, t = await setup(pool)
    async with e.client(t) as c:
        lumi = (await c.get("/companions")).json()[0]
        other = (await c.post("/companions", json={"name": "阿满"})).json()
        await c.patch(f"/companions/{other['id']}", json={"settings": {"relationship": "family", "recall_level": "rich"}})
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 3, "careful_read": False,
                                                                      "relationship": "friend", "recall_level": "light"}})
        r = await c.post(f"/companions/{lumi['id']}/sync-advanced")
        assert r.status_code == 200 and r.json() == {"copied": 1}
        s = (await c.get(f"/companions/{other['id']}")).json()
        assert s["settings"]["reply_wait"] == 3 and s["settings"]["careful_read"] is False
        assert s["settings"]["relationship"] == "family" and s["settings"]["recall_level"] == "rich"
        assert s["name"] == "阿满"


# ── 第 4 步：加钥匙先试打、模型清单 ──

async def test_add_key_probes_first(pool):
    from llm.errors import LLMError
    e, t = await setup(pool)
    e.deps.probe_keys = True
    e.model.script = [LLMError("auth", "invalid api key", status=401), LLMError("balance", "no credit", status=402), "hi"]
    async with e.client(t) as c:
        body = {"provider": "deepseek", "api_key": "sk-abcdefgh1234", "chat_model": "deepseek-flash"}
        r = await c.post("/keys", json=body)
        assert r.status_code == 400 and "key 不对" in r.json()["detail"]
        r = await c.post("/keys", json=body)
        assert r.status_code == 400 and "余额不足" in r.json()["detail"]
        assert (await c.get("/keys")).json() == []
        r = await c.post("/keys", json=body)
        assert r.status_code == 201 and r.json()["last4"] == "1234"
    probe = e.model.requests[-1]
    assert probe.max_tokens == 1 and probe.model == "deepseek-flash" and not probe.thinking


async def test_models_catalog(pool):
    e, t = await setup(pool)
    async with e.client(t) as c:
        ms = (await c.get("/models", params={"provider": "deepseek"})).json()
    assert {m["id"] for m in ms} >= {"deepseek-flash"}
    flash = next(m for m in ms if m["id"] == "deepseek-flash")
    assert flash["price_in"] == 0.30 and flash["price_out"] == 1.20 and flash["label"]


async def test_factory_persona_text_never_leaves_the_server(pool):
    # 09-29 Tilia：出厂性格是底子，用户看不见；想自己写可以一键清空，清空了就回到出厂
    from brain.persona import FACTORY
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        r = (await c.get(f"/companions/{comp['id']}")).json()
        assert r["persona"]["personality"] == "" and r["persona"]["style"] == ""
        assert set(r["persona"]["factory"]) == {"personality", "style"}
        assert FACTORY["zh"].personality[:20] not in json.dumps(r, ensure_ascii=False)
        r = (await c.patch(f"/companions/{comp['id']}", json={"persona": {"personality": "我是个话痨"}})).json()
        assert r["persona"]["personality"] == "我是个话痨" and r["persona"]["factory"] == ["style"]
        r = (await c.patch(f"/companions/{comp['id']}", json={"persona": {"personality": "  "}})).json()   # 清空 = 回到出厂
        assert r["persona"]["personality"] == "" and "personality" in r["persona"]["factory"]
    assert "personality" not in (await archive.get_persona(pool, UUID(comp["id"])) or {})
