"""精排：把问话和候选记忆成对地读一遍，给每条打 0~1 的「对得上」分。
真跑用本地 bge-reranker-v2-m3（Apache-2.0，跟 bge-m3 一家，中英都懂，首次下载约 2.3GB）；
测试用 MapReranker 查表给分。"""
from __future__ import annotations

import threading
from typing import Protocol

import numpy as np


class Reranker(Protocol):
    def score(self, query: str, docs: list[str]) -> list[float]: ...


class MapReranker:
    def __init__(self, scores: dict[str, float], default: float = 0.0):
        self.scores = scores
        self.default = default

    def score(self, query: str, docs: list[str]) -> list[float]:
        return [self.scores.get(d, self.default) for d in docs]


class BgeReranker:
    """一次只让一个线程加载、打分（09-28：超时之后下一句又起一个加载，两个线程抢 GPU，Metal 直接崩）。"""

    def __init__(self, model_name: str = "BAAI/bge-reranker-v2-m3"):
        self.model_name = model_name
        self._model = None
        self._lock = threading.Lock()

    @property
    def ready(self) -> bool:
        """模型加载好了没有：没好之前的那一句不算超时（冷启动要几秒）。"""
        return self._model is not None

    def score(self, query: str, docs: list[str]) -> list[float]:
        if not docs:
            return []
        with self._lock:
            if self._model is None:
                from sentence_transformers import CrossEncoder
                self._model = CrossEncoder(self.model_name)
            # sentence-transformers 6 的 CrossEncoder 自己已经过了一次 sigmoid，给的就是 0~1。
            # 09-28 之前这里又压了一遍，所有分都挤在 0.50~0.52，细读等于没开（门槛从没起过作用）。
            probs = np.asarray(self._model.predict([(query, d) for d in docs]), dtype=np.float64)
        return probs.tolist()
