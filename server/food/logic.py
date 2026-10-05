"""饮食的纯逻辑（09-29 搬自 fed-myself —— Tilia 和 Quercus自己写的，MIT）。Mele 这边改了：目标多了「只记录」（默认，不设目标）
和减脂 / 维持 / 增重；估算改成一条一条、只回 JSON（服务器后台马上估，不等 AI 来拉）。

Food log — pure logic (no network, no database).

A calorie & macro diary designed to be shared with an AI companion:
the user writes what they ate in their own words; entries without numbers
are "pending" and get estimated by the AI (or by the user).

Targets come from either
- manual: daily kcal + protein typed in by the user
- body:   height / weight / age / activity → Mifflin-St Jeor BMR × activity factor

Exercise does NOT raise the target: calories burned are subtracted from what was eaten,
so  net = eaten − exercise  and  remaining = target − net.
The diary never judges: the bar fills towards the target, going over just stays full.
"""
from __future__ import annotations

import re

MEALS = ["早餐", "午餐", "晚餐", "加餐"]
EXERCISE = "运动"
KINDS = MEALS + [EXERCISE]

ACTIVITY = {             # 活动系数（Mifflin-St Jeor 常用那套）
    "sedentary": 1.2,    # 基本坐着
    "light": 1.375,      # 每周轻运动 1~3 次
    "moderate": 1.55,    # 每周认真运动 3~5 次
}

GOALS = ("record", "lose", "keep", "gain", "manual")   # 只记录（默认）/ 减脂 / 维持 / 增重 / 手填
DEFAULT_SETTINGS = {
    "goal": "record",
    "mode": "body",
    "height_cm": 165, "weight_kg": 60, "age": 30, "sex": "f",
    "activity": "sedentary",
    "kcal": 1800, "protein": 90,
    "remark": True,          # 记完 Lumi 说一句（09-30 Tilia：默认开）
}


def bmr(height_cm: float, weight_kg: float, age: float, sex: str = "f") -> float:
    base = 10 * weight_kg + 6.25 * height_cm - 5 * age
    return base - 161 if sex == "f" else base + 5


def targets(settings: dict | None) -> dict | None:
    """设置 → 每日目标 {kcal, protein, carbs, fat, bmr, tdee}；「只记录」= None（不设目标，页面不出「还差多少」）。
    减脂 / 增重都是温和的：缺口 15%（最多 500），盈余 300。脂肪按 30% 热量，碳水填剩下的。"""
    s = {**DEFAULT_SETTINGS, **(settings or {})}
    goal = s.get("goal") or ("manual" if s.get("mode") == "manual" else "record")
    if goal not in GOALS or goal == "record":
        return None
    b = bmr(float(s["height_cm"]), float(s["weight_kg"]), float(s["age"]), s.get("sex", "f"))
    tdee = b * ACTIVITY.get(s.get("activity"), 1.2)
    if goal == "manual":
        kcal = float(s.get("kcal") or tdee)
        protein = float(s.get("protein") or 1.5 * float(s["weight_kg"]))
    else:
        kcal = {"lose": tdee - min(500.0, tdee * 0.15), "keep": tdee, "gain": tdee + 300}[goal]
        protein = 1.5 * float(s["weight_kg"])
    fat = kcal * 0.30 / 9
    carbs = max(0.0, (kcal - protein * 4 - fat * 9) / 4)
    return {"kcal": round(kcal), "protein": round(protein), "carbs": round(carbs),
            "fat": round(fat), "bmr": round(b), "tdee": round(tdee)}


def _num(v):
    try:
        f = float(v)
        return f if f >= 0 else None
    except (TypeError, ValueError):
        return None


def clean_entry(payload: dict) -> tuple[dict | None, str]:
    """An entry from the app or the AI → normalised fields. Returns (entry, error).
    No kcal = pending: waiting for the AI (or the user) to fill in the numbers."""
    kind = str(payload.get("meal") or "").strip()
    if kind not in KINDS:
        return None, f"meal 只能是 {'/'.join(KINDS)}"
    text = str(payload.get("text") or "").strip()[:300]
    if not text:
        return None, "写一下吃了什么 / 做了什么运动"
    entry = {"meal": kind, "text": text,
             "photo": str(payload.get("photo") or "").strip()[:300],
             # text = what was eaten; detail = what's in it, in the user's own words ("half an onion");
             # detail_est = the AI's gram-by-gram version ("onion ~75g"); portion = whole serving size
             "detail": str(payload.get("detail") or "").strip()[:400],
             "detail_est": str(payload.get("detail_est") or "").strip()[:400],
             "portion": str(payload.get("portion") or "").strip()[:40]}
    for k in ("kcal", "protein", "carbs", "fat"):
        entry[k] = _num(payload.get(k))
    if kind == EXERCISE:
        entry["protein"] = entry["carbs"] = entry["fat"] = None
    entry["status"] = "pending" if entry["kcal"] is None else "done"
    return entry, ""


def summary(entries: list, tgt: dict | None) -> dict:
    """一天的综述。只算已经有数的；待估的单独计数。没目标（只记录）就不给 remaining / reached。"""
    intake = {"kcal": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
    exercise = 0.0
    pending = 0
    for e in entries:
        if e.get("kcal") is None:
            pending += 1
            continue
        if e.get("meal") == EXERCISE:
            exercise += float(e["kcal"])
            continue
        for k in intake:
            intake[k] += float(e.get(k) or 0)
    net = intake["kcal"] - exercise
    out = {k: round(v) for k, v in intake.items()}
    out.update({
        "exercise": round(exercise),
        "net": round(net),
        **({"remaining": max(0, round(tgt["kcal"] - net)),  # 还剩多少到目标；到了就是 0，不出负数
            "reached": net >= tgt["kcal"]} if tgt else {}),
        "pending": pending,
        "meals": {m: round(sum(float(e.get("kcal") or 0) for e in entries if e.get("meal") == m))
                  for m in KINDS},
    })
    return out


def _bare(text: str) -> str:
    return re.sub(r"\s*[（(][^（）()]*[）)]", "", str(text or "")).strip()


def day_blurb(entries: list, limit: int = 60) -> str:
    """列表页那一行：早餐:xx/xx · 午餐:xx……"""
    parts = []
    for m in MEALS:
        # only the food itself on the list page — amounts / ingredients in brackets are dropped
        items = [_bare(e["text"]) for e in entries if e.get("meal") == m]
        items = [x for x in items if x]
        if items:
            parts.append(f"{m}:" + "/".join(items))
    text = " · ".join(parts)
    return text if len(text) <= limit else text[:limit - 1] + "…"


PHOTO_ONLY = "拍的这一餐"      # 只拍了照片没写名字（app 那边同一个字）：估的时候让模型顺便起个名


ESTIMATE_SYSTEM = {"zh": "你在帮人估一餐饭的热量和营养。只回 JSON，不聊天。",
                   "en": "You estimate the calories and macros of a meal. Reply with JSON only; no chat."}


def _past_line(r: dict, lang: str) -> str:
    what = r["text"] + (f"（{r['detail']}）" if lang == "zh" and r.get("detail") else f" ({r['detail']})" if r.get("detail") else "")
    was = f"{round(r['est_kcal'])}" + (f"（{r['est_portion']}）" if lang == "zh" and r.get("est_portion") else
                                      f" ({r['est_portion']})" if r.get("est_portion") else "")
    return f"- {what}：估 {was} → TA 改成 {round(r['kcal'])}" if lang == "zh" else f"- {what}: estimated {was} → changed to {round(r['kcal'])}"


def estimate_prompt(entry: dict, photos: int = 0, lang: str = "zh", *, where: str = "", past=()) -> str:
    """估一条：只给这一条的字，不带 TA 生活里的别的东西。运动只要消耗的 kcal。
    09-30（Tilia）：where = TA 在哪（国家代码或时区），按当地常见份量估；past = TA 以前手改过的估算，当参考。"""
    ex = entry.get("meal") == EXERCISE
    ref = ""
    if not ex:
        if where:
            ref += (f"\nTA 在 {where}：按当地常见的份量和做法估（同一样东西，各地的一份差很多）。" if lang == "zh" else
                    f"\nThey're in {where}: use the typical local portion and recipe (the same item varies a lot by country).")
        if past:
            ref += (("\nTA 以前改过的估算（说明 TA 平时吃的份量，参考着估，别照搬）：\n" if lang == "zh" else
                     "\nPast estimates they corrected (shows their usual portions; use as a reference, don't copy):\n")
                    + "\n".join(_past_line(r, lang) for r in past))
    if lang == "zh":
        head = f"{'运动' if ex else entry.get('meal', '')}：{entry.get('text', '')}"
        if entry.get("detail"):
            head += f"｜{'时长' if ex else '里面'}：{entry['detail']}"
        pic = (f"\n附了 {photos} 张照片：拍的是营养成分表就照表上每 100g 的数乘吃的量（没写量就按一份）；拍的是饭就看图估，几张一起看。"
               if photos else "")
        ask = ('只回一个 JSON：{"kcal": 消耗的千卡}' if ex else
               '只回一个 JSON：{"kcal": 千卡, "protein": 克, "carbs": 克, "fat": 克, "portion": "约 420g", '
               '"note": "一句话：按什么估的"' + (', "name": "照片里是什么，几个字"' if entry.get("text") == PHOTO_ONLY else "") + '}')
        return f"{head}{pic}{ref}\n按常见份量估，估准就好，别往多估也别往少估。{ask}"
    head = f"{'Exercise' if ex else entry.get('meal', '')}: {entry.get('text', '')}"
    if entry.get("detail"):
        head += f" | {'duration' if ex else 'contents'}: {entry['detail']}"
    pic = (f"\n{photos} photo(s) attached: if it's a nutrition label, scale the per-100g values by the amount eaten "
           f"(one serving if not stated); if it's food, estimate from the pictures together." if photos else "")
    ask = ('Reply with one JSON object only: {"kcal": kcal burned}' if ex else
           'Reply with one JSON object only: {"kcal": kcal, "protein": g, "carbs": g, "fat": g, "portion": "~420g", '
           '"note": "one line: what you based it on"' + (', "name": "what the photo shows, a few words"'
                                                         if entry.get("text") == PHOTO_ONLY else "") + '}')
    return f"{head}{pic}{ref}\nUse typical portions; aim for accurate, not high or low. {ask}"


_JSON = re.compile(r"\{.*\}", re.S)


def parse_estimate(text: str) -> dict | None:
    """模型回的字 → {kcal, protein, carbs, fat, portion, note}；没有 JSON、kcal 不是正数都当没估出来。"""
    import json
    m = _JSON.search(text or "")
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    kcal = _num(d.get("kcal"))
    if not kcal:
        return None
    out = {"kcal": round(kcal)}
    for k in ("protein", "carbs", "fat"):
        v = _num(d.get(k))
        out[k] = round(v, 1) if v is not None else None
    out["portion"] = str(d.get("portion") or "").strip()[:40]
    out["note"] = str(d.get("note") or "").strip()[:120]
    out["name"] = str(d.get("name") or "").strip()[:60]
    return out


# ── Nutrition lookup (Open Food Facts: free, open data, no API key) ──────────────
# Data © Open Food Facts contributors, ODbL. https://world.openfoodfacts.org

def _off_num(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f, 1)


def off_products(data: dict, limit: int = 5) -> list[dict]:
    """Open Food Facts 搜索结果 → 几行干净的：名字、牌子、每 100g 的热量和三大营养素、一份多少。
    没有热量数字的跳过（没用）。"""
    out = []
    for p in (data or {}).get("products") or []:
        n = p.get("nutriments") or {}
        kcal = _off_num(n.get("energy-kcal_100g"))
        if kcal is None and _off_num(n.get("energy_100g")) is not None:
            kcal = round(_off_num(n.get("energy_100g")) / 4.184, 1)   # 只给了 kJ
        name = str(p.get("product_name") or "").strip()
        if kcal is None or not name:
            continue
        out.append({
            "name": name[:80],
            "brand": str(p.get("brands") or "").split(",")[0].strip()[:40],
            "kcal_100g": kcal,
            "protein_100g": _off_num(n.get("proteins_100g")),
            "carbs_100g": _off_num(n.get("carbohydrates_100g")),
            "fat_100g": _off_num(n.get("fat_100g")),
            "serving": str(p.get("serving_size") or "").strip()[:30],
            "kcal_serving": _off_num(n.get("energy-kcal_serving")),
        })
        if len(out) >= limit:
            break
    return out


def off_line(p: dict) -> str:
    macros = "/".join("?" if p.get(k) is None else f"{p[k]:g}" for k in ("protein_100g", "carbs_100g", "fat_100g"))
    serving = f"；一份 {p['serving']}" + (f" ≈ {p['kcal_serving']:g} kcal" if p.get("kcal_serving") else "") if p.get("serving") else ""
    brand = f"（{p['brand']}）" if p.get("brand") else ""
    pack = f"，整包 {p['package']}" if p.get("package") else ""
    return f"{p['name']}{brand}：每 100g {p['kcal_100g']:g} kcal，蛋白/碳水/脂肪 {macros} g{serving}{pack}"
