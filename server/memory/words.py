"""分词：把一句话切成关键词检索用的词。中文用 jieba（搜索模式，长词和里面的短词都要），
英文转小写。只留字母数字汉字组成的词——这样拼进 tsquery 不会有注入或语法错误。"""
import logging
import re

import jieba

jieba.setLogLevel(logging.WARNING)

_KEEP = re.compile(r"^[0-9a-z一-鿿]+$")
_CJK_CHAR = re.compile(r"^[一-鿿]$")
_CJK_RUN = re.compile(r"[一-鿿]+")

STOPWORDS = frozenset(
    "的 了 是 我 你 他 她 它 在 和 就 都 也 很 吗 呢 吧 啊 呀 嗯 哦 这 那 一个 什么 怎么 "
    "the a an and or of to in on is are was were be i you he she it my your".split()
)


def tokens(text: str, stop=frozenset()) -> list[str]:
    """stop：这个用户额外的停用词（称呼、他库里太常见的词，见 memory/stopwords.py）。"""
    out: list[str] = []
    for t in jieba.lcut_for_search((text or "").lower()):
        t = t.strip()
        if not t or not _KEEP.match(t) or t in STOPWORDS or t in stop:
            continue
        if len(t) < 2 and not _CJK_CHAR.match(t) and not t.isdigit():
            continue  # 单个英文字母太泛
        out.append(t)
    return out


def search_text(text: str) -> str:
    return " ".join(tokens(text))


def tsquery(text: str, stop=frozenset()) -> str:
    return " | ".join(dict.fromkeys(tokens(text, stop)))


def cjk_bigrams(text: str) -> list[str]:
    out: list[str] = []
    for run in _CJK_RUN.findall(text or ""):
        out.extend(run[i:i + 2] for i in range(len(run) - 1))
    return out
