"""TA 在听什么，Mele 关着的时候（09-30，音乐第 7 步）。苹果不让 App 在后台一直看「音乐」在放什么，
所以巡逻每 5 分钟替连了 Apple Music、最近 12 小时开过 app 的人问一次「最近播放」：换歌了就存进〔TA 那边〕的 music
（playing=false，「刚才在听」），顺手记成听过（私选不推）。手机 20 分钟内报过的更准，不拉。"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from brain import accounts, archive, context_line

from . import store as S
from .find import alt_names
from .picks import song_key

log = logging.getLogger(__name__)
EVERY = timedelta(minutes=5)
ACTIVE = timedelta(hours=12)
_last: dict[str, datetime] = {}


def reset() -> None:
    _last.clear()


async def poll(deps, now: datetime) -> int:
    """返回这一趟存了几个人的新歌。"""
    am, box = getattr(deps, "music", None), getattr(getattr(deps, "keys", None), "box", None)
    if am is None or box is None:
        return 0
    if "at" in _last and now - _last["at"] < EVERY:
        return 0
    _last["at"] = now
    pool, saved = deps.pool, 0
    rows = await pool.fetch("""SELECT m.account_id FROM music_links m JOIN accounts a ON a.id = m.account_id
                               WHERE m.platform = 'apple' AND m.user_token IS NOT NULL AND a.last_active_at >= $1""",
                            now - ACTIVE)
    for r in rows:
        acc = r["account_id"]
        try:
            have = (await context_line.load(pool, acc)).get("music")
            if have and have[0].get("playing") and now - have[1] <= context_line.MAX_AGE["music"]:
                continue                                        # 手机刚报过，更准
            link = await S.get_link(pool, box, acc)
            got = await am.recent_tracks(link.user_token, 1) if link and link.user_token else []
            if not got or (have and have[0].get("song_id") == got[0].id):
                continue
            latest = got[0]
            comps = await accounts.list_companions(pool, acc)
            lang = (await archive.get_settings(pool, comps[0])).get("lang") or "zh" if comps else "zh"
            alt = (await alt_names(am, [latest.id], link.storefront, lang)).get(latest.id)
            name, artist = (alt.name, alt.artist) if alt else (latest.name, latest.artist)
            await context_line.save(pool, acc, "music", {"song_id": latest.id, "name": name, "artist": artist,
                                                         "playing": False}, now)
            await S.note_heard(pool, acc, [song_key(latest.name, latest.artist)])
            saved += 1
        except Exception:                                       # noqa: BLE001 —— 甜点，一个人出错不耽误别人
            log.exception("music poll %s failed", acc)
    return saved
