import numpy as np

from memory.embed import FakeEmbedder, embed_one


def cos(a, b):
    return float(np.dot(a, b))


def test_fake_embedder_shape_and_unit_length():
    e = FakeEmbedder()
    v = e.embed(["芒果过敏", ""])
    assert v.shape == (2, 1024) and v.dtype == np.float32
    assert np.allclose(np.linalg.norm(v, axis=1), 1.0)


def test_fake_embedder_similar_texts_closer():
    e = FakeEmbedder()
    a, b, c = e.embed(["小满对芒果过敏", "芒果过敏怎么办", "今天去游泳"])
    assert cos(a, b) > cos(a, c)


def test_fake_embedder_deterministic():
    e = FakeEmbedder()
    assert np.array_equal(e.embed(["hello world"]), e.embed(["hello world"]))


class Broken:
    dim = 1024

    def embed(self, texts):
        raise RuntimeError("model down")


async def test_embed_one_returns_none_on_failure():
    assert await embed_one(Broken(), "x") is None


async def test_embed_one_returns_vector():
    v = await embed_one(FakeEmbedder(), "芒果")
    assert v.shape == (1024,)
