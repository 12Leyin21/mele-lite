"""耳朵第 1 步：量数字 + 翻成一句事实（09-30）。"""
import numpy as np
import soundfile as sf

from music import ears_numbers as N


def _click_track(path, bpm=120.0, seconds=12.0, sr=22050):
    """每拍一个咔哒 + 一直响的 A 音：拍子清楚、调性偏 A。"""
    t = np.arange(int(seconds * sr)) / sr
    y = 0.2 * np.sin(2 * np.pi * 440 * t)
    step = int(sr * 60 / bpm)
    click = np.hanning(400) * 0.9
    for i in range(0, len(y) - 400, step):
        y[i:i + 400] += click
    sf.write(path, y.astype(np.float32), sr)
    return seconds


def test_numbers_hears_the_beat(tmp_path):
    p = tmp_path / "a.wav"
    secs = _click_track(str(p))
    got = N.numbers(str(p))
    assert 115 <= got["tempo"] <= 125
    assert got["pulse_clarity"] > 0.3
    assert abs(got["listened_s"] - secs) < 0.5
    assert set(got) >= {"tempo", "key", "brightness", "pulse_clarity", "onset_rate", "dynamics_db",
                        "peak_at_s", "quietest_at_s", "listened_s"}


def test_describe_zh_facts_not_feelings():
    s = N.describe({"tempo": 0, "key": "A 小调", "brightness": 0.1, "pulse_clarity": 0.1,
                    "onset_rate": 1.0, "dynamics_db": 20}, "zh")
    assert "没有明确的拍子" in s and "偏暗" in s and "A 小调" in s and "30 秒试听" in s


def test_describe_en_has_no_chinese():
    s = N.describe({"tempo": 128, "key": "C 大调", "brightness": 0.6, "pulse_clarity": 0.7,
                    "onset_rate": 5.0, "dynamics_db": 5}, "en")
    assert "128 BPM, or possibly a 64 BPM slow song" in s and "C major" in s
    assert not any("一" <= ch <= "鿿" for ch in s)


def test_fast_reading_admits_it_might_be_a_slow_song_counted_double():
    s = N.describe({"tempo": 136.0, "brightness": 0.6, "pulse_clarity": 0.5}, "zh")
    assert "136 BPM，也可能是 68 的慢歌被量成了双拍" in s and "撑着人往前跑" not in s
    assert "跟平静时的心跳差不多" in N.describe({"tempo": 80.0}, "zh")
