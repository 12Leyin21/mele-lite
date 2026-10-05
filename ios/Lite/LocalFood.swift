#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 饮食（照 server/api/routes_food.py + food/logic.py，那套本来是Tilia 和 Quercus的 fed-myself，MIT）。
/// 记、改、删、目标、封面在手机上；没写热量的那条用你的 key 估；查营养直接从手机问 Open Food Facts（免费公开，不要钥匙）。
enum LocalFood {
    static let meals = ["早餐", "午餐", "晚餐", "加餐"]
    static let exercise = "运动"
    static let photoOnly = "拍的这一餐"
    static let defaults: [String: Any] = ["goal": "record", "mode": "body", "height_cm": 165, "weight_kg": 60, "age": 30,
                                          "sex": "f", "activity": "sedentary", "kcal": 1800, "protein": 90, "remark": true]

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        guard p.first == "food" else { return nil }
        let s = host.store
        switch (r.method, p.count > 1 ? p[1] : "", p.count) {
        case ("GET", "days", 2): return .json(days(s, q: r.query["q"] ?? "", limit: Int(r.query["limit"] ?? "60") ?? 60))
        case ("GET", "day", 3): return .json(dayView(s, p[2]))
        case ("POST", "entry", 2): return add(host, r.json)
        case ("PATCH", "entry", 3): return update(host, Int(p[2]), r.json)
        case ("DELETE", "entry", 3): return LocalRooms.removeWhere(s, "food", 404, String(localized: "没有这条")) { ($0["id"] as? Int) == Int(p[2]) }
        case ("POST", "photo", 2):
            guard let f = r.form.files["file"]?.first, let img = UIImage(data: f.data), let jpg = LocalBrain.jpeg(img, maxSide: 1600) else {
                return .error(400, String(localized: "饮食只收照片"))
            }
            let id = UUID().uuidString.lowercased()
            s.saveFile(jpg, name: "att-\(id)")
            s.saveCollection("attachments", s.collection("attachments") + [["id": id, "conversation": NSNull(), "kind": "image",
                                                                             "name": f.name, "mime": "image/jpeg", "size": jpg.count]])
            return .json(["id": id, "url": "/attachments/\(id)"], status: 201)
        case ("GET", "settings", 2): let st = settings(s); return .json(st.merging(["targets": targets(st) ?? NSNull()]) { a, _ in a })
        case ("PUT", "settings", 2):
            var st = settings(s)
            for k in ["goal", "height_cm", "weight_kg", "age", "sex", "activity", "kcal", "protein", "country", "remark"] where r.json[k] != nil {
                st[k] = r.json[k]
            }
            s.write("food-settings.json", st)
            return .json(st.merging(["targets": targets(st) ?? NSNull()]) { a, _ in a })
        case ("POST", "cover", 2):
            var covers = s.read("food-covers.json") as? [String: String] ?? [:]
            let day = r.json["date"] as? String ?? ""
            guard !day.isEmpty else { return .error(400, "要带 date") }
            let att = "\(r.json["url"] ?? r.json["id"] ?? "")".split(separator: "/").last.map(String.init) ?? ""
            covers[day] = att.isEmpty ? nil : att
            s.write("food-covers.json", covers)
            return .empty
        case ("GET", "barcode", 3): return await barcode(p[2])
        case ("GET", "lookup", 2): return await lookup(r.query["q"] ?? "", country: r.query["country"].flatMap { $0.isEmpty ? nil : $0 } ?? (settings(s)["country"] as? String ?? "world"), limit: Int(r.query["limit"] ?? "5") ?? 5)
        default: return nil
        }
    }

    // MARK: 设置和目标（Mifflin-St Jeor；减脂缺口 15% 最多 500，增重 +300）

    static func settings(_ s: LocalStore) -> [String: Any] {
        defaults.merging(s.read("food-settings.json") as? [String: Any] ?? [:]) { _, new in new }
    }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d >= 0 ? d : nil }
        if let i = v as? Int { return i >= 0 ? Double(i) : nil }
        if let s = v as? String, let d = Double(s) { return d >= 0 ? d : nil }
        return nil
    }

    static func targets(_ st: [String: Any]) -> [String: Any]? {
        let goal = st["goal"] as? String ?? "record"
        guard ["lose", "keep", "gain", "manual"].contains(goal) else { return nil }
        let h = num(st["height_cm"]) ?? 165, w = num(st["weight_kg"]) ?? 60, age = num(st["age"]) ?? 30
        let base = 10 * w + 6.25 * h - 5 * age
        let bmr = (st["sex"] as? String ?? "f") == "f" ? base - 161 : base + 5
        let tdee = bmr * (["sedentary": 1.2, "light": 1.375, "moderate": 1.55][st["activity"] as? String ?? ""] ?? 1.2)
        var kcal: Double, protein: Double
        if goal == "manual" {
            kcal = num(st["kcal"]) ?? tdee
            protein = num(st["protein"]) ?? 1.5 * w
        } else {
            kcal = goal == "lose" ? tdee - min(500, tdee * 0.15) : goal == "gain" ? tdee + 300 : tdee
            protein = 1.5 * w
        }
        let fat = kcal * 0.30 / 9
        let carbs = max(0, (kcal - protein * 4 - fat * 9) / 4)
        return ["kcal": Int(kcal.rounded()), "protein": Int(protein.rounded()), "carbs": Int(carbs.rounded()),
                "fat": Int(fat.rounded()), "bmr": Int(bmr.rounded()), "tdee": Int(tdee.rounded())]
    }

    // MARK: 一天

    static func entryOut(_ e: [String: Any]) -> [String: Any] {
        var o = e
        o["photos"] = (e["photo_ids"] as? [String] ?? []).map { ["id": $0, "url": "/attachments/\($0)"] }
        o.removeValue(forKey: "photo_ids")
        return o
    }

    static func entries(_ s: LocalStore, day: String) -> [[String: Any]] {
        s.collection("food").filter { ($0["date"] as? String) == day }.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }.map(entryOut)
    }

    static func summary(_ es: [[String: Any]], _ tgt: [String: Any]?) -> [String: Any] {
        var intake: [String: Double] = ["kcal": 0, "protein": 0, "carbs": 0, "fat": 0]
        var burned = 0.0, pending = 0
        for e in es {
            guard let k = num(e["kcal"]) else { pending += 1; continue }
            if (e["meal"] as? String) == exercise { burned += k; continue }
            for key in intake.keys { intake[key]! += num(e[key]) ?? 0 }
        }
        let net = intake["kcal"]! - burned
        var out: [String: Any] = intake.mapValues { Int($0.rounded()) }
        out["exercise"] = Int(burned.rounded())
        out["net"] = Int(net.rounded())
        if let tgt, let tk = tgt["kcal"] as? Int {
            out["remaining"] = max(0, Int((Double(tk) - net).rounded()))
            out["reached"] = net >= Double(tk)
        }
        out["pending"] = pending
        var mealsOut: [String: Int] = [:]
        for m in meals + [exercise] { mealsOut[m] = Int(es.filter { ($0["meal"] as? String) == m }.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }.rounded()) }
        out["meals"] = mealsOut
        return out
    }

    static func cover(_ s: LocalStore, day: String, _ es: [[String: Any]]) -> String {
        if let c = (s.read("food-covers.json") as? [String: String])?[day] { return "attachments/\(c)" }
        let first = es.lazy.compactMap { ($0["photos"] as? [[String: Any]])?.first?["url"] as? String }.first
        return first.map { String($0.drop(while: { $0 == "/" })) } ?? ""
    }

    static func dayView(_ s: LocalStore, _ day: String) -> [String: Any] {
        let es = entries(s, day: day)
        let tgt = targets(settings(s))
        return ["date": day, "entries": es, "targets": tgt ?? NSNull(), "summary": summary(es, tgt), "cover": cover(s, day: day, es)]
    }

    static func bare(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s*[（(][^（）()]*[）)]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func days(_ s: LocalStore, q: String, limit: Int) -> [[String: Any]] {
        let all = s.collection("food")
        let needle = q.trimmingCharacters(in: .whitespaces)
        let ds = Set(all.filter { needle.isEmpty || ($0["text"] as? String ?? "").localizedCaseInsensitiveContains(needle) }.compactMap { $0["date"] as? String })
        return ds.sorted(by: >).prefix(max(1, min(limit, 400))).map { day in
            let es = entries(s, day: day)
            let sm = summary(es, nil)
            var parts: [String] = []
            for m in meals {
                let items = es.filter { ($0["meal"] as? String) == m }.map { bare($0["text"] as? String ?? "") }.filter { !$0.isEmpty }
                if !items.isEmpty { parts.append("\(m):" + items.joined(separator: "/")) }
            }
            var blurb = parts.joined(separator: " · ")
            if blurb.count > 60 { blurb = String(blurb.prefix(59)) + "…" }
            return ["date": day, "kcal": sm["kcal"] ?? 0, "net": sm["net"] ?? 0, "pending": sm["pending"] ?? 0, "blurb": blurb,
                    "photo": cover(s, day: day, es)]
        }
    }

    // MARK: 记一条

    static func clean(_ b: [String: Any]) -> ([String: Any]?, String) {
        let meal = (b["meal"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard (meals + [exercise]).contains(meal) else { return (nil, "meal 只能是 " + (meals + [exercise]).joined(separator: "/")) }
        let text = String((b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !text.isEmpty else { return (nil, String(localized: "写一下吃了什么 / 做了什么运动")) }
        var e: [String: Any] = ["meal": meal, "text": text,
                                "detail": String((b["detail"] as? String ?? "").prefix(400)),
                                "portion": String((b["portion"] as? String ?? "").prefix(40))]
        for k in ["kcal", "protein", "carbs", "fat"] { e[k] = num(b[k]).map { k == "kcal" ? Double(Int($0.rounded())) : ($0 * 10).rounded() / 10 } ?? NSNull() }
        if meal == exercise { e["protein"] = NSNull(); e["carbs"] = NSNull(); e["fat"] = NSNull() }
        return (e, "")
    }

    static func add(_ host: LocalHost, _ b: [String: Any]) -> LocalResponse {
        let (clean, err) = clean(b)
        guard var e = clean else { return .error(400, err) }
        let now = LocalStore.iso(Date())
        e["id"] = host.store.nextID("food")
        e["date"] = (b["day"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? LocalRooms.today()
        e["status"] = e["kcal"] is NSNull ? "pending" : "manual"
        e["note"] = ""
        e["source"] = b["source"] as? String == "watch" ? "watch" : "app"
        e["told"] = false                                   // TA 自己记的：估好后下一轮告诉它（它用工具记的会标回 true）
        e["ext_id"] = b["ext_id"] ?? NSNull()
        e["photo_ids"] = b["photos"] as? [String] ?? []
        e["created_at"] = now; e["updated_at"] = now
        if let ext = b["ext_id"] as? String, host.store.collection("food").contains(where: { ($0["ext_id"] as? String) == ext }) {
            return .error(400, String(localized: "这条已经记过了"))
        }
        host.store.saveCollection("food", host.store.collection("food") + [e])
        if e["status"] as? String == "pending" { estimate(host, id: e["id"] as? Int ?? 0) }
        return .json(entryOut(e), status: 201)
    }

    static func update(_ host: LocalHost, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = host.store.collection("food")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这条")) }
        var merged = all[i]
        for (k, v) in b { merged[k] = v }
        let (clean, err) = clean(merged)
        guard let c = clean else { return .error(400, err) }
        for (k, v) in c { all[i][k] = v }
        if let ph = b["photos"] as? [String] { all[i]["photo_ids"] = ph }
        if let d = b["day"] as? String, !d.isEmpty { all[i]["date"] = d }
        all[i]["status"] = all[i]["kcal"] is NSNull ? "pending" : (b.keys.contains("kcal") ? "manual" : all[i]["status"] ?? "manual")
        all[i]["updated_at"] = LocalStore.iso(Date())
        host.store.saveCollection("food", all)
        if all[i]["status"] as? String == "pending" { estimate(host, id: id) }
        return .json(entryOut(all[i]))
    }

    /// 估一条（照 food/logic.py 的 estimate_prompt / parse_estimate）：只给这一条的字和照片
    static func estimate(_ host: LocalHost, id: Int) {
        Task.detached {
            let s = host.store
            guard let comp = s.companions.first(where: { c in host.route(for: c).map { !LiteConsent.book.needsAsk($0.0) } ?? false }),
                  let (provider, key) = host.route(for: comp),
                  let e = s.collection("food").first(where: { ($0["id"] as? Int) == id }) else { return }
            let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
            let ex = (e["meal"] as? String) == exercise
            let photos = (e["photo_ids"] as? [String] ?? []).compactMap { pid -> Data? in
                guard let d = try? Data(contentsOf: s.fileURL("att-\(pid)")), let img = UIImage(data: d) else { return nil }
                return LocalBrain.jpeg(img, maxSide: 1024)
            }
            let text = e["text"] as? String ?? "", detail = e["detail"] as? String ?? ""
            var head = zh ? "\(ex ? "运动" : e["meal"] as? String ?? "")：\(text)" : "\(ex ? "Exercise" : e["meal"] as? String ?? ""): \(text)"
            if !detail.isEmpty { head += zh ? "｜\(ex ? "时长" : "里面")：\(detail)" : " | \(ex ? "duration" : "contents"): \(detail)" }
            let pic = photos.isEmpty ? "" : (zh ? "\n附了 \(photos.count) 张照片：拍的是营养成分表就照表上每 100g 的数乘吃的量（没写量就按一份）；拍的是饭就看图估。"
                                                : "\n\(photos.count) photo(s) attached: if it's a nutrition label, scale per-100g values by the amount eaten; if it's food, estimate from the picture.")
            let nameAsk = text == photoOnly ? (zh ? ", \"name\": \"照片里是什么，几个字\"" : ", \"name\": \"what the photo shows\"") : ""
            let ask = ex ? (zh ? "只回一个 JSON：{\"kcal\": 消耗的千卡}" : "Reply with one JSON object only: {\"kcal\": kcal burned}")
                         : (zh ? "只回一个 JSON：{\"kcal\": 千卡, \"protein\": 克, \"carbs\": 克, \"fat\": 克, \"portion\": \"约 420g\", \"note\": \"一句话：按什么估的\"\(nameAsk)}"
                               : "Reply with one JSON object only: {\"kcal\": kcal, \"protein\": g, \"carbs\": g, \"fat\": g, \"portion\": \"~420g\", \"note\": \"one line\"\(nameAsk)}")
            let prompt = "\(head)\(pic)\n" + (zh ? "按常见份量估，估准就好，别往多估也别往少估。" : "Use typical portions; aim for accurate. ") + ask
            var turns = [ChatTurn(role: .user, text: prompt, imageJPEG: photos.first)]
            if photos.count > 1 { turns = [ChatTurn(role: .user, text: prompt, imageJPEG: photos[0])] }
            let req = ChatRequest(system: zh ? "你在帮人估一餐饭的热量和营养。只回 JSON，不聊天。" : "You estimate the calories and macros of a meal. Reply with JSON only; no chat.",
                                  turns: turns, maxTokens: 800)
            var out = ""
            do { for try await ev in makeClient(provider, key: key).stream(req) { if case .text(let t) = ev { out += t } } } catch { return }
            guard let r = out.range(of: #"\{.*\}"#, options: .regularExpression),
                  let d = try? JSONSerialization.jsonObject(with: Data(out[r].utf8)) as? [String: Any],
                  let kcal = num(d["kcal"]), kcal > 0 else { return }
            var all = s.collection("food")
            guard let i = all.firstIndex(where: { ($0["id"] as? Int) == id }), all[i]["status"] as? String == "pending" else { return }
            all[i]["kcal"] = Double(Int(kcal.rounded()))
            if !ex { for k in ["protein", "carbs", "fat"] { all[i][k] = num(d[k]).map { ($0 * 10).rounded() / 10 } ?? NSNull() } }
            all[i]["portion"] = String("\(d["portion"] ?? "")".prefix(40))
            all[i]["note"] = String("\(d["note"] ?? "")".prefix(120))
            if text == photoOnly, let n = d["name"] as? String, !n.isEmpty { all[i]["text"] = String(n.prefix(60)) }
            all[i]["status"] = "done"
            all[i]["updated_at"] = LocalStore.iso(Date())
            s.saveCollection("food", all)
        }
    }

    // MARK: 查营养（Open Food Facts：免费开放数据，不要钥匙；数据 © Open Food Facts contributors，ODbL）

    static let fields = "product_name,brands,nutriments,serving_size"

    static func get(_ url: String, _ params: [String: String]) async -> (Int, [String: Any]) {
        var c = URLComponents(string: url)!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!, timeoutInterval: 12)
        req.setValue("MeleLite/1.0 (food diary)", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else { return (0, [:]) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
    }

    static func products(_ data: [String: Any], limit: Int) -> [[String: Any]] {
        func n(_ v: Any?) -> Double? { num(v).map { ($0 * 10).rounded() / 10 } }
        var out: [[String: Any]] = []
        for p in data["products"] as? [[String: Any]] ?? [] {
            let nu = p["nutriments"] as? [String: Any] ?? [:]
            var kcal = n(nu["energy-kcal_100g"])
            if kcal == nil, let kj = n(nu["energy_100g"]) { kcal = (kj / 4.184 * 10).rounded() / 10 }
            let name = (p["product_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let kcal, !name.isEmpty else { continue }
            let brand = (p["brands"] as? String ?? "").split(separator: ",").first.map { String($0) } ?? ""
            var item: [String: Any] = [:]
            item["name"] = String(name.prefix(80))
            item["brand"] = String(brand.trimmingCharacters(in: .whitespaces).prefix(40))
            item["kcal_100g"] = kcal
            item["protein_100g"] = n(nu["proteins_100g"]) ?? NSNull()
            item["carbs_100g"] = n(nu["carbohydrates_100g"]) ?? NSNull()
            item["fat_100g"] = n(nu["fat_100g"]) ?? NSNull()
            item["serving"] = String((p["serving_size"] as? String ?? "").prefix(30))
            item["kcal_serving"] = n(nu["energy-kcal_serving"]) ?? NSNull()
            out.append(item)
            if out.count >= limit { break }
        }
        return out
    }

    static func line(_ p: [String: Any]) -> String {
        func f(_ v: Any?) -> String { (v as? Double).map { String(format: "%g", $0) } ?? "?" }
        let macros = [f(p["protein_100g"]), f(p["carbs_100g"]), f(p["fat_100g"])].joined(separator: "/")
        let brand = (p["brand"] as? String ?? "").isEmpty ? "" : "（\(p["brand"]!)）"
        return "\(p["name"] ?? "")\(brand)：每 100g \(f(p["kcal_100g"])) kcal，蛋白/碳水/脂肪 \(macros) g"
    }

    static func barcode(_ raw: String) async -> LocalResponse {
        let code = String(raw.filter(\.isNumber).prefix(14))
        guard code.count >= 8 else { return .error(400, String(localized: "条码不对")) }
        let (status, d) = await get("https://world.openfoodfacts.org/api/v2/product/\(code).json", ["fields": fields])
        let found = status == 200 && (d["status"] as? Int) == 1 ? products(["products": [d["product"] ?? [:]]], limit: 1) : []
        let product: Any = found.first ?? NSNull()
        return .json(["found": !found.isEmpty, "product": product, "code": code])
    }

    static func lookup(_ q: String, country raw: String, limit: Int) async -> LocalResponse {
        let q = String(q.trimmingCharacters(in: .whitespaces).prefix(80))
        guard !q.isEmpty else { return .error(400, String(localized: "查什么？")) }
        let country = String(raw.lowercased().filter(\.isLetter).prefix(8)).isEmpty ? "world" : String(raw.lowercased().filter(\.isLetter).prefix(8))
        let lim = max(1, min(20, limit))
        let params = ["search_terms": q, "search_simple": "1", "json": "1", "page_size": "\(max(12, lim * 2))", "fields": fields]
        var answered = false
        for host in ["\(country).openfoodfacts.org"] + (country == "world" ? [] : ["world.openfoodfacts.org"]) {
            let (status, d) = await get("https://\(host)/cgi/search.pl", params)
            guard status == 200 else { continue }
            answered = true
            let found = products(d, limit: lim)
            if !found.isEmpty {
                return .json(["source": "Open Food Facts (\(host.split(separator: ".")[0]))", "products": found, "lines": found.map(line)])
            }
        }
        guard answered else { return .error(502, String(localized: "Open Food Facts 现在没回，过一会儿再试")) }
        return .json(["source": "Open Food Facts", "products": [Any](), "lines": [Any]()])
    }
}
#endif
