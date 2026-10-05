"""起床前醒来准备（10-01）：每个账号一个早上的钟，起床前半小时；一定开口、静音推送、不占每天的份；每天挂下一次。测试用小满。"""
import json
from datetime import datetime, timedelta, timezone

from brain.settings import Settings
from patrol import morning
from patrol.loop import tick_once
from push.apns import payload
from test_api import Env

TZ_SG = "Asia/Singapore"
T0 = datetime(2026, 10, 1, 22, 0, tzinfo=timezone.utc)            # 新加坡 10-02 06:00


def test_next_time_is_half_an_hour_before_waking():
    s = Settings.from_dict({"tz": TZ_SG, "sleep_to": "07:00"})
    assert morning.next_time(T0 - timedelta(minutes=5), s) == datetime(2026, 10, 1, 22, 30, tzinfo=timezone.utc)
    assert morning.next_time(T0 + timedelta(hours=1), s) == datetime(2026, 10, 2, 22, 30, tzinfo=timezone.utc)   # 过了 = 明天
    s0 = Settings.from_dict({"tz": TZ_SG, "sleep_to": "00:15"})
    assert morning.next_time(T0, s0).astimezone(timezone.utc) == datetime(2026, 10, 2, 15, 45, tzinfo=timezone.utc)  # 跨午夜往前推


def test_quiet_push_has_no_sound():
    assert "sound" not in payload("Lumi", "早", "c", "p", quiet=True)["aps"]
    assert payload("Lumi", "早", "c", "p")["aps"]["sound"] == "default"


async def test_morning_wakes_speaks_quietly_and_rearms(pool):
    e = Env(pool, ["早呀，今天下午两点试镜，带伞"] * 3)              # 心跳也可能同一趟醒，剧本多给几句
    clock = {"now": T0 - timedelta(hours=1)}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "sleep_to": "07:00", "reply_wait": 0}})
        await pool.execute("DELETE FROM clocks WHERE kind = 'morning'")                     # 按新作息重挂
        await tick_once(e.deps, e.rooms)
        at = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'morning'")
        assert at == datetime(2026, 10, 1, 22, 30, tzinfo=timezone.utc)                      # 新加坡 06:30
        await c.post("/me/devices", json={"apns_token": "tok"})
        clock["now"] = at + timedelta(seconds=10)
        await tick_once(e.deps, e.rooms)
    asks = ["\n".join(m.text for m in r.messages) for r in e.model.requests]
    ask = next(a for a in asks if "快到 TA 起床的时间了" in a)
    assert "一定要开口" in ask
    row = await pool.fetchrow("SELECT text, quiet, urgent FROM push_queue WHERE quiet ORDER BY id DESC LIMIT 1")
    assert row["text"].startswith("早呀") and row["quiet"] and not row["urgent"]
    nxt = await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'morning'")
    assert nxt == datetime(2026, 10, 2, 22, 30, tzinfo=timezone.utc)                         # 明天同一时间
    assert await pool.fetchval("SELECT count(*) FROM wake_log WHERE reason = 'morning' AND outcome = 'said'") == 1


async def test_morning_has_its_own_switch_not_heartbeat(pool):
    e = Env(pool, ["早"] * 3)
    clock = {"now": T0 - timedelta(hours=1)}
    e.deps.now = lambda: clock["now"]
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": TZ_SG, "sleep_to": "07:00", "heartbeat_on": False}})
        await pool.execute("DELETE FROM clocks WHERE kind = 'morning'")
        await tick_once(e.deps, e.rooms)
        clock["now"] = datetime(2026, 10, 1, 22, 30, 10, tzinfo=timezone.utc)
        await tick_once(e.deps, e.rooms)                                        # 心跳关着：早上照样来
        assert await pool.fetchval("SELECT count(*) FROM wake_log WHERE reason = 'morning' AND outcome = 'said'") == 1
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"morning_on": False}})
        clock["now"] = datetime(2026, 10, 2, 22, 30, 10, tzinfo=timezone.utc)
        await tick_once(e.deps, e.rooms)                                        # 早上关了：不来，挪到明天
        assert await pool.fetchval("SELECT count(*) FROM wake_log WHERE reason = 'morning'") == 1
        assert await pool.fetchval("SELECT next_at FROM clocks WHERE kind = 'morning'") > clock["now"]
