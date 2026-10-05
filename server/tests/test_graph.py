import importlib

from memory import people, store

# memory.graph 这个名字被对外同名函数占了，这里要的是模块本身
graph = importlib.import_module("memory.graph")
from memory.embed import FakeEmbedder

E = FakeEmbedder()


async def test_graph_nodes_and_edges(pool, user_a):
    a = (await store.remember(pool, E, user_a, "年糕是一只橘猫，四岁")).memory
    b = (await store.remember(pool, E, user_a, "年糕是橘猫，上周打了疫苗")).memory
    c = (await store.remember(pool, E, user_a, "Mia is training for a half marathon")).memory
    p = await people.upsert_person(pool, E, user_a, "阿杰", relation="好朋友")
    d = (await store.remember(pool, E, user_a, "和阿杰约好圣诞去塔斯马尼亚")).memory

    g = await graph.graph(pool, user_a, min_sim=0.3)
    ids = {n.id for n in g.nodes}
    assert ids == {a.id, b.id, c.id, p.id, d.id}
    pairs = {(e.kind, frozenset((e.source, e.target))) for e in g.edges}
    assert ("similar", frozenset((a.id, b.id))) in pairs
    assert ("person", frozenset((p.id, d.id))) in pairs
    assert not any(c.id in pair for kind, pair in pairs if kind == "similar")
    label = {n.id: n.label for n in g.nodes}
    assert label[p.id] == "阿杰"


async def test_graph_empty(pool, user_a):
    g = await graph.graph(pool, user_a)
    assert g.nodes == [] and g.edges == []
    assert g.to_dict() == {"nodes": [], "edges": []}
