"""耳朵的数字那层（09-30，移植自之前自用的 App 的中继 song_ears.py 的 listen / describe，作者 12Leyin21）。

只出事实，不出形容词：「暗」「炸开」留给 Lumi 自己说。阈值全是之前自用的 App 2026-08-12 拿八首反差极大的歌
（德彪西到 Metallica）实测校准的——改之前先重跑校准，别凭手感调。
我们只有 Apple 的 30 秒试听，所以不切段（之前自用的 App的结构分段短于 75 秒本来就不出）。

librosa 很吃 CPU，服务器上在子进程里跑：`nice -n 10 python -m music.ears_numbers a.wav` 打印 JSON。"""
from __future__ import annotations

import json
import math
import sys

_PITCHES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Krumhansl-Schmuckler 调性感知权重：跟实际的音级分布做相关，最像的那个就是调
_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


def _key_of(chroma) -> str:
    import numpy as np
    profile = chroma.mean(axis=1)
    if profile.sum() <= 0:
        return ""
    profile = profile / profile.sum()

    def corr(template, shift):
        rolled = np.roll(template, shift)
        a, b = profile - profile.mean(), rolled - rolled.mean()
        denom = math.sqrt(float((a ** 2).sum()) * float((b ** 2).sum()))
        return float((a * b).sum() / denom) if denom else -1.0

    best = max(((corr(np.array(_MAJOR), i), i, "大调") for i in range(12)), key=lambda x: x[0])
    best_minor = max(((corr(np.array(_MINOR), i), i, "小调") for i in range(12)), key=lambda x: x[0])
    if best_minor[0] > best[0]:
        best = best_minor
    return f"{_PITCHES[best[1]]} {best[2]}"


def numbers(path: str) -> dict:
    """听一个音频文件（wav），返回量出来的数字。"""
    import librosa
    import librosa.feature.rhythm
    import numpy as np

    y, sr = librosa.load(path, sr=22050, mono=True)
    duration = len(y) / sr
    if duration < 3:
        raise RuntimeError("音频太短，听不出东西")

    tempo = float(librosa.feature.rhythm.tempo(y=y, sr=sr, aggregate=np.median)[0])
    key = _key_of(librosa.feature.chroma_cqt(y=y, sr=sr))

    # 亮度：频谱重心 / 4000Hz。实测 0.13（氛围乐）~ 0.74（亮面电子），中位数 0.46
    centroid = float(np.mean(librosa.feature.spectral_centroid(y=y, sr=sr)))
    brightness = round(min(1.0, centroid / 4000.0), 3)

    # 拍子有多明确：起音曲线的自相关有多周期（不是「鼓有多重」——HPSS 那版把 Metallica 判得比氛围乐还轻）
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    centered = onset_env - onset_env.mean()
    max_lag = min(len(centered), int(4 * sr / 512))
    ac = librosa.autocorrelate(centered, max_size=max_lag)
    min_lag = max(1, int(60 / 240 * sr / 512))          # 快过 240 BPM 的当噪声
    pulse = float(ac[min_lag:].max() / (ac[0] + 1e-9)) if len(ac) > min_lag else 0.0
    pulse_clarity = round(max(0.0, min(1.0, pulse)), 3)
    onsets = librosa.onset.onset_detect(onset_envelope=onset_env, sr=sr)
    onset_rate = round(len(onsets) / max(1.0, duration), 2)

    # 起伏：响度的动态范围（dB）
    rms = librosa.feature.rms(y=y)[0]
    db = 20 * np.log10(rms + 1e-9)
    dynamics = round(float(np.percentile(db, 95)) - float(np.percentile(db, 10)), 1)

    # 最响 / 最静：3 秒滑窗；找最静处跳过头尾各 8%（不然永远指向淡入淡出）
    win = max(1, int(3 * sr / 512))
    if len(rms) > win:
        smooth = np.convolve(rms, np.ones(win) / win, mode="same")
        peak_at = round(float(np.argmax(smooth) * 512 / sr), 1)
        edge = int(len(smooth) * 0.08)
        inner = smooth[edge:len(smooth) - edge] if len(smooth) > 2 * edge else smooth
        quiet_at = round(float((np.argmin(inner) + edge) * 512 / sr), 1)
    else:
        peak_at = quiet_at = 0.0

    return {
        # 拍子不清楚就不报 BPM（节拍跟踪器会把《Clair de Lune》报成 172）
        "tempo": round(tempo, 1) if pulse_clarity >= 0.12 else 0,
        "key": key, "brightness": brightness, "pulse_clarity": pulse_clarity, "onset_rate": onset_rate,
        "dynamics_db": dynamics, "peak_at_s": peak_at, "quietest_at_s": quiet_at, "listened_s": round(duration, 1),
    }


_ZH = {
    "pace": ["比心跳慢，是能靠着听的那种", "跟平静时的心跳差不多", "比心跳快一点，走起来了", "很快，撑着人往前跑"],
    "free": "没有明确的拍子，是自由走的",
    "double": "{t:.0f} BPM，也可能是 {h:.0f} 的慢歌被量成了双拍——快慢以听到的走向为准",
    "bright": ["整首偏暗、偏闷，高频很少", "暖的，不刺耳", "亮度居中", "偏亮", "很亮，高频推得靠前"],
    "pulse": ["节奏很松，几乎是随着人声走的", "有拍子但不硬", "节奏站得很稳", "节奏顶在最前面，踩得很实"],
    "sparse": "很空，音与音之间留了很多气口", "dense": "很密，一直有东西在响",
    "flat": "从头到尾一个音量，压得很平", "swing": "起伏很大（{db:.0f} dB），有真的安静下来的地方",
    "sep": "；", "end": "。", "preview": " （只听了苹果给的 30 秒试听，还没听过全曲。）",
}
_EN = {
    "pace": ["slower than a heartbeat, the lean-back kind", "about a resting heartbeat",
             "a little faster than a heartbeat, it's moving", "fast, pushing you forward"],
    "free": "no clear beat, it moves freely",
    "double": "{t:.0f} BPM, or possibly a {h:.0f} BPM slow song counted double — go by how it actually moves",
    "bright": ["dark and muffled overall, very little top end", "warm, not harsh", "middling brightness", "on the bright side",
               "very bright, the highs pushed forward"],
    "pulse": ["loose rhythm, almost following the voice", "there's a beat but it's soft", "a steady rhythm",
              "the rhythm is right up front, hitting hard"],
    "sparse": "very sparse, lots of air between the notes", "dense": "very dense, something is always sounding",
    "flat": "one volume from start to end, heavily compressed", "swing": "big swings ({db:.0f} dB), with truly quiet moments",
    "sep": "; ", "end": ".", "preview": " (Only heard Apple's 30-second preview, not the whole song.)",
}


DOUBLE_FROM = 120


def _band(x: float, edges: list[float]) -> int:
    return next((i for i, e in enumerate(edges) if x < e), len(edges))


def describe(nums: dict, lang: str = "zh") -> str:
    """把数字翻成一段事实（之前自用的 App原句）。只陈述听到了什么，不替它抒情。"""
    w = _ZH if lang == "zh" else _EN
    bits = []
    tempo = nums.get("tempo") or 0
    # 30 秒试听上节拍跟踪器常把慢歌量成两倍（09-30：晴天常见标 68，量成 136，写成了「很快」）。
    # 120 以上不写死快慢，两个数都给，让它对着听感里的「走向」自己判断
    if not tempo:
        bits.append(w["free"])
    elif tempo >= DOUBLE_FROM:
        bits.append(w["double"].format(t=tempo, h=tempo / 2))
    else:
        bits.append(f"{tempo:.0f} BPM——{w['pace'][_band(tempo, [70, 100, 130])]}")
    if nums.get("key"):
        k = nums["key"]
        bits.append(k if lang == "zh" else k.replace("大调", "major").replace("小调", "minor"))
    bits.append(w["bright"][_band(nums.get("brightness", 0), [0.20, 0.35, 0.55, 0.70])])
    bits.append(w["pulse"][_band(nums.get("pulse_clarity", 0), [0.25, 0.45, 0.62])])
    rate = nums.get("onset_rate", 0)
    if rate and rate < 1.6:
        bits.append(w["sparse"])
    elif rate > 4.5:
        bits.append(w["dense"])
    dyn = nums.get("dynamics_db", 0)
    if dyn < 8:
        bits.append(w["flat"])
    elif dyn > 18:
        bits.append(w["swing"].format(db=dyn))
    text = w["sep"].join(bits) + w["end"] + w["preview"]
    return text if lang == "zh" else text.replace("——", " — ")


if __name__ == "__main__":
    print(json.dumps(numbers(sys.argv[1]), ensure_ascii=False))
