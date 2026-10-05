"""塔罗的九个牌阵（10-03）。只在这里定义一次，手机从 /tarot/spreads 取（之前自用的 App那边要三处对齐，Mele 不这样）。

牌阵本身是塔罗圈的公共知识；坐标和牌位区尺寸是之前自用的 App那版我们自己调的数；usage 文案新写。
positions 的顺序 = 抽牌顺序。layout 是单位坐标 (0~1)，示意图和真牌位都用它。
followup 是「再问一张」的伪牌阵，不进 public()。"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Spread:
    key: str
    name: dict
    usage: dict
    positions: dict
    layout: tuple
    board_height: int
    card_width: int

    @property
    def count(self) -> int:
        return len(self.layout)

    def public(self, lang: str) -> dict:
        return {"key": self.key, "name": self.name[lang], "usage": self.usage[lang], "count": self.count,
                "positions": list(self.positions[lang]), "layout": [list(p) for p in self.layout],
                "board_height": self.board_height, "card_width": self.card_width}


def _s(key, zh, en, uzh, uen, pzh, pen, layout, h, w) -> Spread:
    return Spread(key, {"zh": zh, "en": en}, {"zh": uzh, "en": uen}, {"zh": tuple(pzh), "en": tuple(pen)},
                  tuple(layout), h, w)


SPREADS: dict[str, Spread] = {s.key: s for s in (
    _s("single", "单张", "One card",
       "一句话的小事，抽一张看方向", "A small question — one card for a direction",
       ["指引"], ["Guidance"], [(0.5, 0.5)], 190, 104),
    _s("three", "三张", "Three cards",
       "过去、现在、未来，最顺手的一阵", "Past, present, future — the everyday spread",
       ["过去", "现在", "未来"], ["Past", "Present", "Future"],
       [(0.22, 0.5), (0.5, 0.5), (0.78, 0.5)], 130, 72),
    _s("relationship", "关系", "Relationship",
       "两个人之间：左边是你，右边是对方，中间是这段关系", "Between two people: you on the left, them on the right, the bond in the middle",
       ["我的想法", "我的感受", "我的态度", "对方的想法", "对方的感受", "对方的态度", "关系现状"],
       ["My thoughts", "My feelings", "My stance", "Their thoughts", "Their feelings", "Their stance", "Where we are"],
       [(0.18, 0.18), (0.18, 0.5), (0.18, 0.82), (0.82, 0.18), (0.82, 0.5), (0.82, 0.82), (0.5, 0.5)], 290, 50),
    _s("choice", "二选一", "Two paths",
       "拿不定主意时：底下是现在，两边各看一条路会怎么走", "When you can't decide: now at the bottom, each path's road and end on either side",
       ["现状", "A 的过程", "A 的结果", "B 的过程", "B 的结果"],
       ["Now", "Path A", "Where A leads", "Path B", "Where B leads"],
       [(0.5, 0.84), (0.3, 0.5), (0.15, 0.16), (0.7, 0.5), (0.85, 0.16)], 240, 48),
    _s("diamond", "五张", "Five cards",
       "卡住的事：问题的核心、它从哪来、什么在挡、还能长出什么、该怎么走", "Stuck on something: its heart, its root, what blocks it, what could grow, what to do",
       ["核心", "根源", "阻力", "潜力", "建议"], ["Heart", "Root", "Obstacle", "Potential", "Advice"],
       [(0.5, 0.5), (0.5, 0.84), (0.2, 0.5), (0.8, 0.5), (0.5, 0.16)], 240, 48),
    _s("moon", "月相", "Moon phases",
       "一个月的节奏：新月种下、上弦用力、满月看见、下弦放下", "A month's rhythm: plant at new moon, push at first quarter, see at full, let go at last quarter",
       ["新月", "上弦", "满月", "下弦"], ["New moon", "First quarter", "Full moon", "Last quarter"],
       [(0.14, 0.62), (0.38, 0.38), (0.62, 0.38), (0.86, 0.62)], 200, 60),
    _s("week", "一周", "The week",
       "周一到周日一天一张，周初抽一次", "One card a day, Monday to Sunday — draw at the start of the week",
       ["周一", "周二", "周三", "周四", "周五", "周六", "周日"],
       ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
       [(0.08, 0.68), (0.22, 0.48), (0.36, 0.34), (0.5, 0.28), (0.64, 0.34), (0.78, 0.48), (0.92, 0.68)], 180, 48),
    _s("horseshoe", "马蹄", "Horseshoe",
       "一件事从头到尾：远因、近因、眼下、接下来，外面的力和最后的走向", "One matter end to end: old causes, recent ones, now, next, outside forces and where it goes",
       ["远因", "近因", "眼下", "接下来", "外界", "建议", "走向"],
       ["Distant past", "Recent past", "Now", "Near future", "Outside", "Advice", "Outcome"],
       [(0.1, 0.24), (0.16, 0.58), (0.33, 0.82), (0.5, 0.88), (0.67, 0.82), (0.84, 0.58), (0.9, 0.24)], 180, 48),
    _s("celtic", "凯尔特十字", "Celtic cross",
       "复杂的局面，十张摊开看全貌", "A tangled situation, laid out whole in ten cards",
       ["核心", "交叉", "心里想要", "根基", "刚过去", "快来了", "自己", "周围", "希望与害怕", "走向"],
       ["Heart", "Crossing", "Aim", "Foundation", "Just behind", "Just ahead", "Self", "Surroundings", "Hopes & fears", "Outcome"],
       [(0.32, 0.5), (0.4, 0.56), (0.32, 0.16), (0.32, 0.84), (0.12, 0.5), (0.52, 0.5),
        (0.82, 0.88), (0.82, 0.63), (0.82, 0.38), (0.82, 0.13)], 300, 42),
    _s("followup", "再问一张", "One more",
       "接着这一局再问一句", "One more question on the same reading",
       ["追问"], ["Follow-up"], [(0.5, 0.5)], 190, 104),
)}


def public(lang: str) -> list[dict]:
    return [s.public(lang) for k, s in SPREADS.items() if k != "followup"]
