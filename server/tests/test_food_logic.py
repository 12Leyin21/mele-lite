"""饮食纯逻辑（搬自 fed-myself，09-29）。测试用 Mia 编的数，不用Tilia的身体数据。"""
from food import logic as L

BODY = {"height_cm": 170, "weight_kg": 65, "age": 28, "sex": "f", "activity": "light"}


def test_record_mode_has_no_target():
    assert L.targets(None) is None and L.targets({"goal": "record"}) is None
    s = L.summary([{"meal": "午餐", "kcal": 600}, {"meal": "运动", "kcal": 200}], None)
    assert s["net"] == 400 and "remaining" not in s


def test_goals_are_gentle_and_ordered():
    keep, lose, gain = (L.targets({**BODY, "goal": g})["kcal"] for g in ("keep", "lose", "gain"))
    assert lose < keep < gain and keep - lose <= 500 and gain - keep <= 400
    assert L.targets({**BODY, "goal": "manual", "kcal": 2100})["kcal"] == 2100


def test_summary_subtracts_exercise_and_counts_pending():
    s = L.summary([{"meal": "早餐", "kcal": 400, "protein": 20}, {"meal": "午餐", "kcal": None},
                   {"meal": "运动", "kcal": 150}], {"kcal": 1800})
    assert (s["kcal"], s["exercise"], s["net"], s["remaining"], s["pending"]) == (400, 150, 250, 1550, 1)


def test_parse_estimate():
    assert L.parse_estimate('{"kcal": 650, "protein": 30, "carbs": 80, "fat": 20, "note": "一大碗"}')["kcal"] == 650
    assert L.parse_estimate('```json\n{"kcal": 300}\n```')["kcal"] == 300
    assert L.parse_estimate("我觉得大概 600 卡吧") is None and L.parse_estimate('{"kcal": -5}') is None


def test_estimate_prompt_mentions_photos_and_detail():
    p = L.estimate_prompt({"meal": "午餐", "text": "牛肉面", "detail": "加了个蛋"}, photos=2, lang="zh")
    assert "牛肉面" in p and "加了个蛋" in p and "2 张照片" in p and "JSON" in p


def test_off_products_kj_fallback():
    got = L.off_products({"products": [{"product_name": "燕麦奶", "nutriments": {"energy_100g": 209.2}},
                                       {"product_name": "", "nutriments": {"energy-kcal_100g": 10}}]})
    assert got == [{"name": "燕麦奶", "brand": "", "kcal_100g": 50.0, "protein_100g": None, "carbs_100g": None,
                    "fat_100g": None, "serving": "", "kcal_serving": None}]


OFF_HIT = {"products": [{"product_name": "Oat Milk", "brands": "Oatly,Other", "serving_size": "250ml",
                         "nutriments": {"energy-kcal_100g": 46, "proteins_100g": 1, "carbohydrates_100g": 6.6, "fat_100g": 1.5}}]}


async def test_off_search_country_then_world_and_down(monkeypatch):
    from food import off
    calls = []

    async def get(url, params):
        calls.append(url)
        return (200, {"products": []}) if "au." in url else (200, OFF_HIT)
    r = await off.search("oat milk", "au", 5, get)
    assert r["products"][0]["brand"] == "Oatly" and "world" in r["source"] and calls[0].startswith("https://au.")

    async def down(url, params):
        return 503, {}
    import pytest
    monkeypatch.setattr(off.asyncio, "sleep", _no_sleep)
    with pytest.raises(off.OffDown):
        await off.search("oat milk", "world", 5, down)


async def _no_sleep(_):
    return None


async def test_off_barcode():
    from food import off

    async def get(url, params):
        return 200, {"status": 1, "product": OFF_HIT["products"][0]}
    r = await off.barcode("9300 0000 12345", get)
    assert r["found"] and r["code"] == "9300000012345" and r["product"]["kcal_100g"] == 46
