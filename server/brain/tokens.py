"""粗估 token 数（不调接口）：中日韩字一个算一个，其他字符四个算一个。
只用来给用户报「大概多少钱」；判断要不要卷账本用的是模型报回来的真实数。"""
import math
import re

_CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")


def estimate_tokens(text: str) -> int:
    text = text or ""
    cjk = len(_CJK.findall(text))
    return cjk + math.ceil((len(text) - cjk) / 4)
