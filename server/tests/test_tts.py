"""ElevenLabs 接头（10-03）：路径、头、body、出错分类、价钱。不联网（MockTransport）。"""
import json

import httpx
import pytest

from llm.tts import ElevenLabs, TTSError, tts_cost


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_synth_request_shape():
    seen = {}

    def handler(req: httpx.Request):
        seen.update(path=req.url.path, fmt=req.url.params.get("output_format"), key=req.headers.get("xi-api-key"),
                    body=json.loads(req.content))
        return httpx.Response(200, content=b"ID3mp3")

    e = ElevenLabs("sk_test", client=_client(handler))
    out = await e.synth("[softly] 晚安…", "voice1", previous_text="今天辛苦了")
    assert out == b"ID3mp3"
    assert seen["path"] == "/v1/text-to-speech/voice1" and seen["fmt"] == "mp3_44100_128" and seen["key"] == "sk_test"
    assert seen["body"] == {"text": "[softly] 晚安…", "model_id": "eleven_v4", "voice_settings": {"stability": 0.5},
                            "previous_text": "今天辛苦了"}


async def test_design_save_slots_premade():
    def handler(req: httpx.Request):
        p = req.url.path
        if p == "/v1/text-to-voice/design":
            b = json.loads(req.content)
            assert b["voice_description"] == "低一点、懒洋洋的" and b["auto_generate_text"] is True
            return httpx.Response(200, json={"previews": [{"generated_voice_id": "g1", "audio_base_64": "AA==",
                                                           "duration_secs": 4.2}], "text": "x"})
        if p == "/v1/text-to-voice":
            return httpx.Response(200, json={"voice_id": "v9"})
        if p == "/v1/user/subscription":
            return httpx.Response(200, json={"voice_slots_used": 3, "voice_limit": 30})
        if p == "/v1/voices":
            return httpx.Response(200, json={"voices": [{"voice_id": "a", "name": "A", "category": "premade",
                                                         "preview_url": "u"},
                                                        {"voice_id": "b", "name": "B", "category": "generated"}]})
        return httpx.Response(404)

    e = ElevenLabs("k", client=_client(handler))
    prev = await e.design("低一点、懒洋洋的")
    assert prev[0]["generated_voice_id"] == "g1"
    assert await e.save_design("小满的 Lumi", "低一点", "g1") == "v9"
    assert await e.slots() == (3, 30)
    assert [v["voice_id"] for v in await e.premade()] == ["a"]


@pytest.mark.parametrize("status,kind", [(401, "auth"), (429, "quota"), (422, "bad_request"), (503, "server")])
async def test_errors(status, kind):
    e = ElevenLabs("k", client=_client(lambda req: httpx.Response(status, text="nope")))
    with pytest.raises(TTSError) as err:
        await e.synth("hi", "v")
    assert err.value.kind == kind


def test_cost():
    assert tts_cost(1000, "eleven_v4") == pytest.approx(0.08)
    assert tts_cost(500, "eleven_v4_turbo") == pytest.approx(0.02)


async def test_check_accepts_key_missing_models_permission():
    """只开了部分权限的 key（10-04 实测）：认得这把 key、只是没开 models_read，填 key 时照收；真没权限的那一步再报。"""
    body = '{"detail":{"status":"missing_permissions","message":"missing the permission models_read"}}'
    el = ElevenLabs("k", client=_client(lambda r: httpx.Response(401, text=body)))
    await el.check()
    with pytest.raises(TTSError) as e:
        await el.slots()
    assert e.value.kind == "missing_permissions"


async def test_check_still_rejects_bad_key():
    el = ElevenLabs("k", client=_client(lambda r: httpx.Response(401, json={"detail": {"status": "invalid_api_key"}})))
    with pytest.raises(TTSError) as e:
        await el.check()
    assert e.value.kind == "auth"
