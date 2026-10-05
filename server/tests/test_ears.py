"""耳朵第 2～4 步：歌词、听感、档案、后台听、〔在听〕（09-30）。歌名都是编的 / 公开的歌，不带任何人的数据。"""
import base64
from datetime import datetime, timezone

from music import ears as E

NOW = datetime(2026, 10, 1, 8, 0, tzinfo=timezone.utc)
LRC = "[00:05.00] 第一句\n[00:10.50] 第二句\n\n[00:15.00][00:40.00] 副歌\n[00:20.00]\n"


def test_parse_lrc():
    got = E.parse_lrc(LRC)
    assert got == [{"t": 5.0, "line": "第一句"}, {"t": 10.5, "line": "第二句"}, {"t": 15.0, "line": "副歌"},
                   {"t": 40.0, "line": "副歌"}]


def fake_get(table):
    calls = []

    async def get(url, params):
        calls.append((url.rsplit("/", 1)[1], params.get("track_name")))
        return table.get((url.rsplit("/", 1)[1], params.get("track_name")), (404, None))
    return get, calls


async def test_lrclib_exact_hit():
    get, _ = fake_get({("get", "晴天"): (200, {"syncedLyrics": LRC})})
    assert len(await E.lrclib([("晴天", "周杰伦")], 269, get=get)) == 4


async def test_lrclib_falls_back_to_search_and_checks_duration():
    get, calls = fake_get({("search", "Sunny Day"): (200, [
        {"duration": 300, "syncedLyrics": "[00:01.00] 不对的版本"},
        {"duration": 270, "syncedLyrics": "[00:01.00] 对的"}])})
    assert await E.lrclib([("Sunny Day", "Jay Chou")], 269, get=get) == [{"t": 1.0, "line": "对的"}]
    assert calls == [("get", "Sunny Day"), ("search", "Sunny Day")]


async def test_lrclib_tries_next_name_then_gives_up():
    get, calls = fake_get({("get", "晴天"): (200, {"syncedLyrics": LRC})})
    assert len(await E.lrclib([("Sunny Day", "Jay Chou"), ("晴天", "周杰伦")], 269, get=get)) == 4
    get, _ = fake_get({})
    assert await E.lrclib([("没有这首", "谁")], 100, get=get) == []


async def test_gemini_sends_audio_and_falls_through_models():
    seen = []

    async def post(url, body, headers):
        seen.append(url.split("/models/")[1].split(":")[0])
        if "busy" in url:
            return 503, {}
        parts = body["contents"][0]["parts"]
        assert base64.b64decode(parts[0]["inline_data"]["data"]) == b"MP3"
        assert "《晴天》" in parts[1]["text"] and headers["x-goog-api-key"] == "k"
        return 200, {"candidates": [{"content": {"parts": [{"text": "想了想", "thought": True},
                                                          {"text": "- 人声：男声\n\n**配器**：钢琴"}]}}]}

    got = await E.gemini_impression("k", b"MP3", "晴天", "周杰伦", "zh", post=post, models=["busy", "ok"])
    assert got == "人声：男声\n配器：钢琴" and seen == ["busy", "ok"]


async def test_gemini_fails_quietly():
    async def post(url, body, headers):
        return 400, {"error": "bad"}
    assert await E.gemini_impression("k", b"MP3", "a", "b", "en", post=post, models=["m"]) == ""
    assert await E.gemini_impression("", b"MP3", "a", "b", "en", post=post) == ""


async def test_archive_roundtrip_and_add_language(pool):
    await E.save(pool, "s1", name="晴天", artist="周杰伦", duration_s=269, numbers={"tempo": 69},
                 impression={"zh": "男声"}, lyrics=[{"t": 1.0, "line": "a"}], lyrics_source="lrclib", status="ok", now=NOW)
    await E.add_impression(pool, "s1", "en", "male voice")
    got = await E.get(pool, "s1")
    assert got["numbers"] == {"tempo": 69} and got["impression"] == {"zh": "男声", "en": "male voice"}
    assert got["lyrics"] == [{"t": 1.0, "line": "a"}] and got["status"] == "ok"
    assert await E.get(pool, "nope") is None


# ---- 第 3 步：后台听 --------------------------------------------------------------------------------

from datetime import timedelta  # noqa: E402

from brain.turn import Deps  # noqa: E402
from llm.router import Route  # noqa: E402
from music.apple import Song  # noqa: E402


class FakeMusic:
    async def songs(self, ids, storefront, lang=None):
        if ids == ["gone"]:
            return []
        name, artist = ("晴天", "周杰伦") if lang else ("Sunny Day", "Jay Chou")
        return [Song(i, name, artist, "", "", f"https://p/{i}.m4a", "", duration_ms=269_000) for i in ids]


class FakeTransport:
    def __init__(self, nums=True, words="男声，钢琴", lyrics=True):
        self.nums, self.words, self.lyrics, self.log = nums, words, lyrics, []

    async def download(self, url):
        self.log.append(("download", url))
        return b"M4A"

    async def listen(self, audio):
        self.log.append(("listen", audio))
        return ({"tempo": 69.0, "key": "G 大调"} if self.nums else None), b"MP3"

    async def get(self, url, params):
        self.log.append(("lrclib", params["track_name"]))
        if self.lyrics and params["track_name"] == "晴天" and url.endswith("/get"):
            return 200, {"syncedLyrics": LRC}
        return 404, None

    async def post(self, url, body, headers):
        self.log.append(("gemini", body["contents"][0]["parts"][1]["text"][:6]))
        if not self.words:
            return 500, {}
        return 200, {"candidates": [{"content": {"parts": [{"text": self.words}]}}]}


def deps(pool, t=None, now=NOW):
    return Deps(pool=pool, embedder=None, keys=None, music=FakeMusic(), ears=t or FakeTransport(),
                caption_route=Route("gemini", "k", "m", "m"), now=lambda: now)


async def test_hear_once_shared_by_everyone(pool):
    d = deps(pool)
    assert await E.hear(d, "s1", "au", "zh") == "ok"
    got = await E.get(pool, "s1")
    assert (got["name"], got["duration_s"], got["numbers"]["tempo"]) == ("Sunny Day", 269, 69.0)
    assert got["impression"] == {"zh": "男声，钢琴"} and got["lyrics"][0] == {"t": 5.0, "line": "第一句"}
    assert ("lrclib", "Sunny Day") in d.ears.log and ("lrclib", "晴天") in d.ears.log       # 原名没有，借中文名找到
    d.ears.log.clear()
    assert await E.hear(d, "s1", "us", "zh") == "skip" and d.ears.log == []                # 另一个人放同一首：不重听
    assert await E.hear(d, "s1", "us", "en") == "impression"                               # 英文用户：只补英文听感
    assert set((await E.get(pool, "s1"))["impression"]) == {"zh", "en"}


async def test_hear_failure_waits_six_hours(pool):
    t = FakeTransport(nums=False, words="", lyrics=False)
    assert await E.hear(deps(pool, t), "s2", "au", "zh") == "failed"
    assert (await E.get(pool, "s2"))["status"] == "failed"
    assert await E.hear(deps(pool, FakeTransport()), "s2", "au", "zh") == "skip"
    later = NOW + timedelta(hours=7)
    assert await E.hear(deps(pool, FakeTransport(), later), "s2", "au", "zh") == "ok"
    assert await E.hear(deps(pool), "gone", "au", "zh") == "failed"                       # 曲库里没有


async def test_lyrics_only_still_counts(pool):
    t = FakeTransport(nums=False, words="")
    assert await E.hear(deps(pool, t), "s3", "au", "zh") == "ok"
    assert (await E.get(pool, "s3"))["lyrics"]


async def test_schedule_runs_in_background_and_dedupes(pool):
    d = deps(pool)
    E.schedule(d, "s4", "au", "zh")
    E.schedule(d, "s4", "au", "zh")                    # 同一首正在听：不排第二个
    await E.drain()
    assert sum(1 for x in d.ears.log if x[0] == "download") == 1
    assert (await E.get(pool, "s4"))["status"] == "ok"
    d.ears = None
    E.schedule(d, "s5", "au", "zh")                    # 没开耳朵：不排
    await E.drain()
    assert await E.get(pool, "s5") is None


# ---- 第 4 步：〔在听〕 -----------------------------------------------------------------------------

SONG = {"status": "ok", "numbers": {"tempo": 69.0, "key": "G 大调", "brightness": 0.3, "pulse_clarity": 0.3},
        "impression": {"zh": "人声：男声"}, "duration_s": 60,
        "lyrics": [{"t": 5.0, "line": "第一句"}, {"t": 10.0, "line": "第二句"}, {"t": 15.0, "line": "第三句"}]}
PLAY = {"song_id": "s1", "name": "晴天", "artist": "周杰伦", "playing": True, "position_s": 3.0}


def test_first_line_after_change_is_the_whole_impression_then_two_lyrics():
    st = {}
    first = E.line(SONG, PLAY, NOW, NOW, st, "zh")
    assert first.startswith("〔在听〕TA 那边在放《晴天》- 周杰伦。这首你听过：69 BPM") and "听到的：\n人声：男声" in first
    # 12 秒后又说一句：位置 3 + 12 = 15 → 第二句 + 第三句
    assert E.line(SONG, PLAY, NOW, NOW + timedelta(seconds=12), st, "zh") == "〔在听〕《晴天》，此刻唱到：\n第二句\n第三句"
    # 刚过第一句
    assert E.line(SONG, PLAY, NOW, NOW + timedelta(seconds=3), st, "zh") == "〔在听〕《晴天》，此刻唱到：\n第一句"
    # 还没到第一句：什么都不给
    assert E.line(SONG, {**PLAY, "position_s": 0.0}, NOW, NOW, st, "zh") == ""


def test_whole_impression_again_after_six_hours_not_on_quick_switch_back():
    st = {}
    E.line(SONG, PLAY, NOW, NOW, st, "zh")
    other = {**PLAY, "song_id": "s2", "name": "别的"}
    assert "这首你听过" in E.line(SONG, other, NOW, NOW + timedelta(minutes=4), st, "zh")
    back = NOW + timedelta(minutes=8)
    assert "这首你听过" not in E.line(SONG, PLAY, back, back, st, "zh")          # 换回来不再给整段
    late = NOW + timedelta(hours=6, minutes=1)
    assert "这首你听过" in E.line(SONG, PLAY, late, late, st, "zh")


def test_unheard_said_once_then_whole_when_ready():
    st = {}
    assert E.line(None, PLAY, NOW, NOW, st, "zh") == "〔在听〕TA 那边在放《晴天》- 周杰伦。这首你还没听过。"
    assert E.line(None, PLAY, NOW, NOW + timedelta(seconds=5), st, "zh") == ""
    assert "这首你听过" in E.line(SONG, PLAY, NOW, NOW + timedelta(seconds=30), st, "zh")      # 后台听好了：下一句补整段


def test_nothing_when_stale_paused_or_finished():
    st = {"ears_full": {"s1": NOW.isoformat()}}
    assert E.line(SONG, {**PLAY, "playing": False}, NOW, NOW, st, "zh") == ""
    assert E.line(SONG, PLAY, NOW, NOW + timedelta(minutes=21), st, "zh") == ""
    assert E.line(SONG, {**PLAY, "position_s": 58.0}, NOW, NOW + timedelta(seconds=10), st, "zh") == ""   # 放完了
    assert E.line({**SONG, "lyrics": []}, PLAY, NOW, NOW + timedelta(seconds=12), st, "zh") == ""        # 没歌词
    assert E.line(SONG, {k: v for k, v in PLAY.items() if k != "position_s"}, NOW, NOW, st, "zh") == ""   # 没报位置


def test_english():
    got = E.line(SONG, PLAY, NOW, NOW, {}, "en")
    assert got.startswith("〔Listening〕They're playing \"晴天\" by 周杰伦. You've heard this one: 69 BPM")
    assert "What you heard:\n人声：男声" in got         # 没有英文听感就用有的那份


async def test_for_turn_reads_archive(pool):
    await E.save(pool, "s1", name="晴天", artist="周杰伦", duration_s=60, numbers=SONG["numbers"],
                 impression=SONG["impression"], lyrics=SONG["lyrics"], lyrics_source="lrclib", status="ok", now=NOW)
    assert "这首你听过" in await E.for_turn(pool, {"music": (PLAY, NOW)}, {}, NOW, "zh")
    assert await E.for_turn(pool, {}, {}, NOW, "zh") == ""


async def test_turn_gets_listening_line_instead_of_their_side_music(pool):
    from uuid import UUID

    from brain import context_line as C
    from brain.scope import Scope
    from brain.turn import run_turn
    from test_api import Env

    e = Env(pool, ["嗯嗯", "好呀", "哈哈"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.put("/me/context/place", json={"at_home": True})
        me = UUID((await c.get("/me")).json()["id"])
    now = e.deps.now()
    await E.save(pool, "s1", name="晴天", artist="周杰伦", duration_s=600, numbers=SONG["numbers"],
                 impression=SONG["impression"], lyrics=SONG["lyrics"], lyrics_source="lrclib", status="ok", now=now)
    await C.save(pool, me, "music", {**PLAY, "position_s": 16.0}, now)

    async def emit(_):
        return None
    scope = Scope(me, UUID(comp["id"]), UUID(conv["id"]))
    await run_turn(e.deps, scope, "在吗", emit)
    first = e.model.requests[0].messages[-1].text
    assert "〔在听〕TA 那边在放《晴天》" in first and "〔TA 那边〕在家" in first and "在听《" not in first
    await C.save(pool, me, "music", {**PLAY, "position_s": 16.0}, e.deps.now())       # 手机发消息前又报了一次
    await run_turn(e.deps, scope, "这首好听", emit)
    second = e.model.requests[1].messages[-1].text
    assert "此刻唱到：\n第二句\n第三句" in second and "〔TA 那边〕" not in second      # 位置变了不算「TA 那边变了」
    await run_turn(e.deps, scope, "嗯", emit, wake="〔醒来〕")                          # 醒来不给
    assert "〔在听〕" not in e.model.requests[2].messages[-1].text


def test_lyrics_off_by_default_on_host(monkeypatch):
    monkeypatch.delenv("NEWAPP_LYRICS", raising=False)
    monkeypatch.setenv("NEWAPP_HOST", "1")
    assert E.lyrics_enabled() is False
    monkeypatch.setenv("NEWAPP_LYRICS", "1")
    assert E.lyrics_enabled() is True


def test_lyrics_on_by_default_off_host(monkeypatch):
    monkeypatch.delenv("NEWAPP_LYRICS", raising=False)
    monkeypatch.delenv("NEWAPP_HOST", raising=False)
    assert E.lyrics_enabled() is True
    monkeypatch.setenv("NEWAPP_LYRICS", "0")
    assert E.lyrics_enabled() is False
