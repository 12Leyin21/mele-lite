"""向量。真跑用本地 bge-m3（中英都懂、MIT、不花钱、记忆不出服务器）；
测试用 FakeEmbedder：把词和中文二字组哈希进 1024 个格子——同词多的两句就更像，
够测「像的排前面」，而且完全确定、不用下模型。"""
from __future__ import annotations

import asyncio
import hashlib
import logging
from typing import Protocol

import numpy as np

from . import words

log = logging.getLogger(__name__)
DIM = 1024


class Embedder(Protocol):
    dim: int

    def embed(self, texts: list[str]) -> np.ndarray: ...


class FakeEmbedder:
    dim = DIM

    def embed(self, texts: list[str]) -> np.ndarray:
        out = np.zeros((len(texts), self.dim), dtype=np.float32)
        for i, text in enumerate(texts):
            for feat in words.tokens(text) + words.cjk_bigrams(text):
                h = int(hashlib.md5(feat.encode("utf-8")).hexdigest()[:8], 16)
                out[i, h % self.dim] += 1.0
            norm = np.linalg.norm(out[i])
            if norm == 0:
                out[i, 0] = 1.0   # 空文本也给一个单位向量，免得余弦出 NaN
            else:
                out[i] /= norm
        return out


class BgeM3Embedder:
    """第一次用时才加载模型（约 2.3GB，首次会从 Hugging Face 下载）。"""
    dim = DIM

    def __init__(self, model_name: str = "BAAI/bge-m3"):
        self.model_name = model_name
        self._model = None

    def embed(self, texts: list[str]) -> np.ndarray:
        if self._model is None:
            from sentence_transformers import SentenceTransformer
            self._model = SentenceTransformer(self.model_name)
        vecs = self._model.encode(texts, normalize_embeddings=True, convert_to_numpy=True)
        return vecs.astype(np.float32)


async def embed_one(embedder: Embedder, text: str) -> np.ndarray | None:
    """算一句的向量；模型挂了返回 None（调用方照常存，只是先不带向量）。"""
    try:
        vecs = await asyncio.to_thread(embedder.embed, [text])
        return vecs[0]
    except Exception:
        log.exception("embedding failed")
        return None
