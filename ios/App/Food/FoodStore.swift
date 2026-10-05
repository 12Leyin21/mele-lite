// 搬自 fed-myself（github.com/12Leyin21/fed-myself，MIT，Tilia 和 Quercus写的）· 09-29 接进 Mele
import SwiftUI

/// 饮食记录的数据层。
/// 顶上是「还剩多少到目标」，进度条到了打勾，
/// 超了也只是满着——没有红色、没有警告。运动消耗从吃进去的里扣，目标不变。
/// 手记没填数的是「待估」，服务器攒一分钟递给 AI 估。

enum FoodMeal: String, CaseIterable, Identifiable {
    case breakfast = "早餐", lunch = "午餐", dinner = "晚餐", snack = "加餐", exercise = "运动"
    var id: String { rawValue }
    static let meals: [FoodMeal] = [.breakfast, .lunch, .dinner, .snack]
    var icon: String {
        switch self {
        case .breakfast: "sun.horizon"
        case .lunch: "fork.knife"
        case .dinner: "moon.stars"
        case .snack: "carrot"
        case .exercise: "figure.run"
        }
    }
}

struct FoodPhoto: Codable, Equatable, Hashable {
    let id: String
    let url: String
    /// 给 AuthImageView 的路径（Mele 的接口路径不带开头的 /）
    var path: String { String(url.drop(while: { $0 == "/" })) }
}

struct FoodEntry: Codable, Identifiable, Equatable {
    let id: Int
    let date: String
    let meal: String
    let text: String
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let source: String
    let status: String
    /// 一餐的照片不限张数（Tilia 09-29）；photo = 第一张（列表缩略图用）
    var photos: [FoodPhoto] = []
    var photo: String { photos.first?.path ?? "" }
    /// 用户写的「里面有什么」原话 / 整份多重 / 估算那句话（或者为什么还没估）
    var detail: String? = nil
    var detail_est: String? = nil
    var portion: String? = nil
    var note: String? = nil
    var pending: Bool { status == "pending" }
    /// 只拍了照片的一餐先叫这个，估的时候服务器按照片改名（跟 server/food/logic.py 的 PHOTO_ONLY 一样）
    static let photoOnly = "拍的这一餐"
    var failed: Bool { status == "failed" }
    /// 名字底下那行灰字：整份多重 · 里面有什么
    var subline: String {
        let inside = (detail_est?.isEmpty == false ? detail_est : detail) ?? ""
        return [portion ?? "", inside].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct FoodTargets: Codable, Equatable {
    let kcal: Int
    let protein: Int
    let carbs: Int
    let fat: Int
    let bmr: Int
    let tdee: Int
}

struct FoodSummary: Codable, Equatable {
    let kcal: Int
    let protein: Int
    let carbs: Int
    let fat: Int
    let exercise: Int
    let net: Int
    /// 只记录（没设目标）时没有这两项
    var remaining: Int? = nil
    var reached: Bool? = nil
    let pending: Int
    let meals: [String: Int]
}

struct FoodDay: Codable, Equatable {
    let date: String
    let entries: [FoodEntry]
    /// 只记录（默认）= nil：不设目标，页面不出「还差多少」
    var targets: FoodTargets? = nil
    let summary: FoodSummary
    /// 列表页用的那张封面（自己选的，没选就是第一张有照片的）
    var cover: String? = nil
    func entries(_ meal: FoodMeal) -> [FoodEntry] { entries.filter { $0.meal == meal.rawValue } }
}

struct FoodDayRow: Codable, Identifiable, Equatable {
    let date: String
    let kcal: Int
    let net: Int
    let pending: Int
    let blurb: String
    let photo: String
    var id: String { date }
}

struct FoodSettings: Codable, Equatable {
    /// record 只记录（默认）/ lose 减脂 / keep 维持 / gain 增重 / manual 手填
    var goal: String = "record"
    var mode: String = "body"
    var height_cm: Double
    var weight_kg: Double
    var age: Double
    var sex: String
    var activity: String
    var kcal: Double
    var protein: Double
    /// 记完 AI 说一句（09-30，默认开）
    var remark: Bool = true
}

@MainActor
final class FoodStore: ObservableObject {
    @Published var days: [FoodDayRow] = []
    @Published var day: FoodDay?
    @Published var settings: FoodSettings?
    @Published var targets: FoodTargets?
    @Published var error: String?


    static func today() -> String { dayKey(Date()) }

    /// 某个时刻落在哪一天（「2026-09-25」）
    static func dayKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    /// 「9月25日 · 周四」
    static func label(_ date: String) -> String {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return date }
        var comps = DateComponents(); comps.year = p[0]; comps.month = p[1]; comps.day = p[2]
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.date(from: comps).map { cal.component(.weekday, from: $0) } ?? 1
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "\(p[1])月\(p[2])日 · \(names[(wd - 1) % 7])"
    }

    /// 「Fri 25 Sep」
    static func enLabel(_ date: String) -> String {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return date }
        var comps = DateComponents(); comps.year = p[0]; comps.month = p[1]; comps.day = p[2]
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.date(from: comps).map { cal.component(.weekday, from: $0) } ?? 1
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(days[(wd - 1) % 7]) \(p[2]) \(months[max(0, min(11, p[1] - 1))])"
    }

    private var api: APIClient? { FoodLogConfig.api }

    /// Mele 的接口：出错把服务器的那句人话挂到 error 上
    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                                    as: T.Type) async -> T? {
        guard let api else { error = "没登录"; return nil }
        do {
            let out: T = try await api.call(method, path, query: query, json: body)
            error = nil
            return out
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = "没连上服务器，记录都还在，过会儿再试"
        }
        return nil
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async -> Bool {
        guard let api else { return false }
        do { try await api.send(method, path, json: body); error = nil; return true } catch let e as APIError {
            error = e.message
        } catch { self.error = "没连上服务器，记录都还在，过会儿再试" }
        return false
    }

    private struct SettingsResponse: Decodable {
        let goal: String?; let mode: String?; let height_cm: Double; let weight_kg: Double; let age: Double
        let sex: String; let activity: String; let kcal: Double; let protein: Double; let targets: FoodTargets?
        let remark: Bool?
        var settings: FoodSettings {
            FoodSettings(goal: goal ?? "record", mode: mode ?? "body", height_cm: height_cm, weight_kg: weight_kg, age: age,
                         sex: sex, activity: activity, kcal: kcal, protein: protein, remark: remark ?? true)
        }
    }

    // 截图用假数据（-foodDemo）：没有服务器也能在模拟器里看到样子
    static let demo = ProcessInfo.processInfo.arguments.contains("-foodDemo")
    private static let demoTargets = FoodTargets(kcal: 1694, protein: 98, carbs: 199, fat: 56, bmr: 1412, tdee: 1694)
    private static func demoEntry(_ id: Int, _ meal: String, _ text: String, _ k: Double?, _ p: Double? = nil,
                                  _ c: Double? = nil, _ f: Double? = nil, him: Bool = false) -> FoodEntry {
        FoodEntry(id: id, date: today(), meal: meal, text: text, kcal: k, protein: p, carbs: c, fat: f,
                  source: him ? "lumi" : "app", status: k == nil ? "pending" : "manual")
    }
    private static var demoDay: FoodDay {
        var egg = demoEntry(1, "早餐", "番茄炒蛋", 650, 49, 45, 32, him: false)
        egg.detail = "两个鸡蛋 一个西红柿 半勺油"
        egg.detail_est = "鸡蛋 2 个 ~100g · 西红柿 ~150g · 油 ~7g"
        egg.portion = "约 260g"
        let e = [egg,
                 demoEntry(2, "早餐", "黑麦面包 一片", 82, 3, 15, 1),
                 demoEntry(3, "午餐", "三文鱼牛油果饭", 610, 32, 62, 24),
                 demoEntry(4, "加餐", "月饼 半个", nil),
                 demoEntry(5, "运动", "快走 40 分钟", 160)]
        return FoodDay(date: today(), entries: e, targets: demoTargets,
                       summary: FoodSummary(kcal: 1012, protein: 53, carbs: 91, fat: 46, exercise: 160, net: 852,
                                            remaining: 693, reached: false, pending: 1,
                                            meals: ["早餐": 402, "午餐": 610, "晚餐": 0, "加餐": 0, "运动": 160]))
    }

    func loadDays(query: String = "") async {
        if Self.demo {
            days = [FoodDayRow(date: Self.today(), kcal: 1012, net: 852, pending: 1,
                               blurb: "早餐:番茄炒蛋 一份/黑麦面包 一片 · 午餐:三文鱼牛油果饭 · 加餐:月饼 半个", photo: ""),
                    FoodDayRow(date: "2026-01-01", kcal: 1000, net: 1000, pending: 0,
                               blurb: "早餐:鸡蛋 牛奶 · 午餐:蛋炒饭 · 晚餐:番茄牛腩面", photo: "")]
            targets = Self.demoTargets
            return
        }
        if let r = await call("GET", "food/days", query: [URLQueryItem(name: "limit", value: "120"),
                                                         URLQueryItem(name: "q", value: query)], as: [FoodDayRow].self) {
            days = r
        }
        if targets == nil { await loadSettings() }
    }

    func loadDay(_ date: String) async {
        if Self.demo { day = Self.demoDay; return }
        if let d = await call("GET", "food/day/\(date)", as: FoodDay.self) { day = d }
    }

    func loadSettings() async {
        if let r = await call("GET", "food/settings", as: SettingsResponse.self) {
            settings = r.settings
            targets = r.targets
        }
    }

    func saveSettings(_ s: FoodSettings) async {
        let body: [String: Any] = ["goal": s.goal, "height_cm": s.height_cm, "weight_kg": s.weight_kg,
                                   "age": s.age, "sex": s.sex, "activity": s.activity,
                                   "kcal": s.kcal, "protein": s.protein, "remark": s.remark]
        if let r = await call("PUT", "food/settings", body: body, as: SettingsResponse.self) {
            settings = r.settings
            targets = r.targets
        }
    }

    /// 记一条。数都可以不填——不填就是待估，服务器后台马上估。photos = 已经传好的照片编号
    @discardableResult
    func add(date: String, meal: FoodMeal, text: String, detail: String = "", kcal: Double? = nil,
             protein: Double? = nil, carbs: Double? = nil, fat: Double? = nil, photos: [String] = []) async -> Bool {
        var body: [String: Any] = ["day": date, "meal": meal.rawValue, "text": text, "photos": photos, "detail": detail]
        if let kcal { body["kcal"] = kcal }
        if let protein { body["protein"] = protein }
        if let carbs { body["carbs"] = carbs }
        if let fat { body["fat"] = fat }
        guard await call("POST", "food/entry", body: body, as: FoodEntry.self) != nil else { return false }
        await loadDay(date)
        return true
    }

    func update(_ entry: FoodEntry, text: String, detail: String, kcal: Double?, protein: Double?,
                carbs: Double?, fat: Double?) async {
        var body: [String: Any] = ["text": text, "detail": detail]
        if let kcal { body["kcal"] = kcal; body["protein"] = protein ?? NSNull(); body["carbs"] = carbs ?? NSNull(); body["fat"] = fat ?? NSNull() }
        if await call("PATCH", "food/entry/\(entry.id)", body: body, as: FoodEntry.self) != nil { await loadDay(entry.date) }
    }

    /// 传一张照片，拿回编号（传完先塞进图片缓存，不用再下载一遍）
    func uploadPhoto(_ data: Data) async -> String? {
        guard let api, let r = try? await api.uploadFoodPhoto(data) else { error = "照片没传上去"; return nil }
        AuthImageView.seed(urlPath: r.path, data: data)
        return r.id
    }

    /// 已经记了的一条：照片整组换成 ids（加一张、删一张都走这里）
    func setPhotos(_ entry: FoodEntry, ids: [String]) async -> Bool {
        guard await call("PATCH", "food/entry/\(entry.id)", body: ["photos": ids], as: FoodEntry.self) != nil else { return false }
        await loadDay(entry.date)
        return true
    }

    /// 把这天的某张照片设成列表页封面
    func setCover(date: String, url: String) async {
        if await send("POST", "food/cover", body: ["date": date, "url": url]) { await loadDay(date) }
    }

    /// 导进来的一条（Apple Watch 锻炼）：带 ext_id，服务器记过的 / 删过的不会再记。返回是不是新记的
    func addImported(date: String, text: String, detail: String, kcal: Double?, extID: String) async -> Bool {
        var body: [String: Any] = ["day": date, "meal": FoodMeal.exercise.rawValue, "text": text,
                                   "detail": detail, "source": "watch", "ext_id": extID]
        if let kcal { body["kcal"] = kcal }
        guard let api else { return false }
        return (try? await api.call("POST", "food/entry", json: body) as FoodEntry) != nil
    }

    /// 读手表的锻炼，有新的就刷新页面
    func syncWatch() async {
        guard !Self.demo else { return }
        if await FoodWatchImport.run(into: self) > 0 {
            await loadDays()
            if let d = day?.date { await loadDay(d) }
        }
    }

    func delete(_ entry: FoodEntry) async {
        if await send("DELETE", "food/entry/\(entry.id)") { await loadDay(entry.date) }
    }

    /// 还在估的：前台每 3 秒拉一次这天，最多 1 分钟（后台估一般几秒）
    func watchPending(_ date: String) async {
        for _ in 0..<20 {
            guard day?.entries.contains(where: { $0.pending }) == true else { return }
            try? await Task.sleep(for: .seconds(3))
            await loadDay(date)
        }
    }

    /// 扫到的条码 → Open Food Facts 查这一样东西（服务器转）
    func barcode(_ code: String) async -> BarcodeLookup? {
        await call("GET", "food/barcode/\(code)", as: BarcodeLookup.self)
    }

    /// 按名字搜 Open Food Facts（服务器转）。nil = 没连上。不挂 error：搜不到 / 没连上是搜索页自己说的事
    func search(_ q: String) async -> [BarcodeProduct]? {
        if Self.demo || FoodSearchSheet.demo { return Self.demoSearch }
        guard let api else { return nil }
        let query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "12"),
                     URLQueryItem(name: "country", value: Locale.current.region?.identifier.lowercased() ?? "world")]
        return (try? await api.call("GET", "food/lookup", query: query) as FoodSearchLookup)?.products
    }

    private static let demoSearch: [BarcodeProduct] = [
        BarcodeProduct(name: "梦龙 经典巧克力", brand: "梦龙", kcal_100g: 311, protein_100g: 3.9, carbs_100g: 29,
                       fat_100g: 20, serving: "1 支 (64 g)", kcal_serving: 199),
        BarcodeProduct(name: "Magnum Classic", brand: "Magnum", kcal_100g: 307, protein_100g: 3.7, carbs_100g: 28,
                       fat_100g: 20, serving: "1 stick (79 g)", kcal_serving: 243),
        BarcodeProduct(name: "Magnum Almond", brand: "Magnum", kcal_100g: 336, protein_100g: 4.8, carbs_100g: 28,
                       fat_100g: 22, serving: "1 stick (81 g)", kcal_serving: 272),
        BarcodeProduct(name: "Magnum Mini White", brand: "Magnum", kcal_100g: 276, protein_100g: 3.5, carbs_100g: 27,
                       fat_100g: 17, serving: "1 mini (42 g)", kcal_serving: 116),
        BarcodeProduct(name: "Magnum Double Gold Caramel Billionaire", brand: "Magnum", kcal_100g: 333,
                       protein_100g: 3.6, carbs_100g: 33, fat_100g: 20, serving: "", kcal_serving: nil),
    ]

}
