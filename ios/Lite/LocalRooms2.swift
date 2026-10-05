#if LITE
import CryptoKit
import Foundation
import UIKit
import UserNotifications
import MeleLiteCore

/// 第二批房间：表情包、待办 / 常去的地方、钱包（照 server/api 的 routes_stickers / routes_todos / routes_wallet）
enum LocalRooms2 {
    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        let s = host.store
        switch (r.method, p.first ?? "", p.count) {
        // 表情包
        case ("GET", "stickers", 1): return .json(s.collection("stickers").map(stickerOut))
        case ("POST", "stickers", 1): return uploadStickers(host, r)
        case ("POST", "stickers", 3) where p[1] == "from-attachment": return stickerFromAttachment(host, p[2])
        case ("PATCH", "stickers", 2): return patchSticker(s, Int(p[1]), r.json)
        case ("DELETE", "stickers", 2):
            if let sid = Int(p[1]), let st = s.collection("stickers").first(where: { ($0["id"] as? Int) == sid }) {
                s.removeFile(st["file"] as? String ?? "")
            }
            return LocalRooms.removeWhere(s, "stickers", 404, String(localized: "没有这张")) { ($0["id"] as? Int) == Int(p[1]) }
        case ("GET", "stickers", 3) where p[2] == "image": return stickerImage(s, Int(p[1]))
        case ("POST", "conversations", 4) where p[2] == "stickers": return sendSticker(host, conv: p[1], Int(p[3]))
        // 待办
        case ("GET", "todos", 1): return .json(s.collection("todos").map { todoOut(host, $0) }.sorted { !($0["done"] as? Bool ?? false) && ($1["done"] as? Bool ?? false) })
        case ("POST", "todos", 1): return addTodo(host, r.json)
        case ("PATCH", "todos", 2): return patchTodo(host, Int(p[1]), r.json)
        case ("POST", "todos", 3) where p[2] == "done": return doneTodo(host, Int(p[1]), r.json["done"] as? Bool ?? true)
        case ("DELETE", "todos", 2):
            Reminders.cancel(todo: Int(p[1]) ?? 0)
            return LocalRooms.removeWhere(s, "todos", 404, String(localized: "没有这条待办")) { ($0["id"] as? Int) == Int(p[1]) }
        case ("GET", "places", 1): return .json(s.collection("places"))
        case ("POST", "places", 1): return addPlace(s, r.json)
        case ("PATCH", "places", 2): return LocalRooms.patchItem(s, "places", Int(p[1]), r.json, keys: ["name", "lat", "lon", "radius"])
        case ("DELETE", "places", 2): return LocalRooms.removeWhere(s, "places", 404, String(localized: "没有这个地方")) { ($0["id"] as? Int) == Int(p[1]) }
        case ("POST", "places", 3) where p[2] == "event": return placeEvent(host, Int(p[1]), r.json)
        // 钱包
        case ("GET", "wallet", 1): return .json(walletMonth(s, r.query["month"] ?? ""))
        case ("POST", "wallet", 1): return walletAdd(s, r.json)
        case ("GET", "wallet", 2) where p[1] == "receipt": return .json(walletReceipt(s, r.query["day"].flatMap { $0.isEmpty ? nil : $0 } ?? LocalRooms.today()))
        case ("PUT", "wallet", 2) where p[1] == "settings": return walletSaveSettings(s, r.json)
        case ("PATCH", "wallet", 2): return walletUpdate(s, Int(p[1]), r.json)
        case ("DELETE", "wallet", 2): return LocalRooms.removeWhere(s, "wallet", 404, String(localized: "没有这一笔")) { ($0["id"] as? Int) == Int(p[1]) }
        default: return LocalRooms3.handle(r, host: host)
        }
    }

    // MARK: - 表情包

    static func stickerOut(_ d: [String: Any]) -> [String: Any] {
        ["id": d["id"] ?? 0, "name": d["name"] ?? "", "caption": d["caption"] ?? "", "mime": d["mime"] ?? "image/png",
         "only_for": d["only_for"] ?? [String](), "use_count": d["use_count"] ?? 0]
    }

    static func mime(_ data: Data) -> String {
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/jpeg"
    }

    /// 收一张：同一张图（按指纹）只收一次；收完后台让模型看一眼写描述
    static func addSticker(_ host: LocalHost, _ data: Data, caption: String = "") -> (sticker: [String: Any], new: Bool)? {
        guard UIImage(data: data) != nil else { return nil }
        let s = host.store
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var all = s.collection("stickers")
        if let same = all.first(where: { ($0["sha"] as? String) == sha }) { return (same, false) }
        let id = s.nextID("sticker")
        let file = "sticker-\(id)"
        s.saveFile(data, name: file)
        let st: [String: Any] = ["id": id, "sha": sha, "file": file, "mime": mime(data), "name": "", "caption": caption,
                                 "only_for": [String](), "use_count": 0, "created_at": LocalStore.iso(Date())]
        all.append(st)
        s.saveCollection("stickers", all)
        return (st, true)
    }

    static func uploadStickers(_ host: LocalHost, _ r: LocalRequest) -> LocalResponse {
        var added: [[String: Any]] = [], skipped: [[String: Any]] = []
        for f in r.form.files["files"] ?? [] {
            guard let got = addSticker(host, f.data) else { skipped.append(["name": f.name, "reason": String(localized: "这张图读不出来")]); continue }
            if got.new { added.append(stickerOut(got.sticker)) } else { skipped.append(["name": f.name, "reason": String(localized: "已经收过了")]) }
        }
        captionLater(host)
        return .json(["added": added, "skipped": skipped], status: 201)
    }

    static func stickerFromAttachment(_ host: LocalHost, _ aid: String) -> LocalResponse {
        guard let d = try? Data(contentsOf: host.store.fileURL("att-\(aid)")), let got = addSticker(host, d) else {
            return .error(404, String(localized: "没有这张图"))
        }
        captionLater(host)
        return .json(stickerOut(got.sticker), status: 201)
    }

    static func patchSticker(_ s: LocalStore, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = s.collection("stickers")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这张")) }
        for k in ["name", "caption", "only_for"] where b.keys.contains(k) { all[i][k] = b[k] }
        if b["caption"] != nil { all[i]["captioned"] = true }
        s.saveCollection("stickers", all)
        return .json(stickerOut(all[i]))
    }

    static func stickerImage(_ s: LocalStore, _ id: Int?) -> LocalResponse {
        guard let id, let st = s.collection("stickers").first(where: { ($0["id"] as? Int) == id }),
              let d = try? Data(contentsOf: s.fileURL(st["file"] as? String ?? "")) else { return .error(404, String(localized: "没有这张")) }
        return .data(d, mime: st["mime"] as? String ?? "image/png")
    }

    /// TA 从面板点一张：变成这个窗口的一个附件，发消息时照常带上
    static func sendSticker(_ host: LocalHost, conv: String, _ sid: Int?) -> LocalResponse {
        let s = host.store
        guard let sid, var all = Optional(s.collection("stickers")), let i = all.firstIndex(where: { ($0["id"] as? Int) == sid }),
              let d = try? Data(contentsOf: s.fileURL(all[i]["file"] as? String ?? "")) else { return .error(404, String(localized: "没有这张")) }
        all[i]["use_count"] = (all[i]["use_count"] as? Int ?? 0) + 1
        s.saveCollection("stickers", all)
        let aid = UUID().uuidString.lowercased()
        s.saveFile(d, name: "att-\(aid)")
        var atts = s.collection("attachments")
        atts.append(["id": aid, "conversation": conv, "kind": "image", "name": "sticker-\(sid)", "mime": all[i]["mime"] ?? "image/png", "size": d.count])
        s.saveCollection("attachments", atts)
        return .json(host.attachmentPublic(aid) ?? [:], status: 201)
    }

    /// 还没描述的表情包：用第一个配了 key、同意过的联系人那家模型看一眼
    static func captionLater(_ host: LocalHost) {
        Task.detached {
            let s = host.store
            guard let comp = s.companions.first(where: { c in host.route(for: c).map { !LiteConsent.book.needsAsk($0.0) } ?? false }),
                  let (provider, key) = host.route(for: comp) else { return }
            let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
            let ask = zh ? "这是一张聊天用的表情包。用一句话（20 字以内）说它是什么、表达什么情绪，只写这一句。"
                         : "This is a chat sticker. In one short line (under 12 words), say what it shows and the feeling it expresses. Write only that line."
            for st in s.collection("stickers") where (st["caption"] as? String ?? "").isEmpty {
                guard let d = try? Data(contentsOf: s.fileURL(st["file"] as? String ?? "")), let img = UIImage(data: d),
                      let jpeg = LocalBrain.jpeg(img, maxSide: 512) else { continue }
                var text = ""
                do {
                    let req = ChatRequest(system: "", turns: [ChatTurn(role: .user, text: ask, imageJPEG: jpeg)], maxTokens: 200)
                    for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
                } catch { return }
                var all = s.collection("stickers")
                if let i = all.firstIndex(where: { ($0["id"] as? Int) == (st["id"] as? Int) }) {
                    all[i]["caption"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    s.saveCollection("stickers", all)
                }
            }
        }
    }

    // MARK: - 待办（照 brain/todos.py：once = 做完就完；at = 每天 / 每周；到点用手机本地提醒）

    static func period(_ t: [String: Any]) -> String {
        switch t["shape"] as? String {
        case "at": return ((t["spec"] as? [String: Any])?["days"] as? [Int] ?? []).isEmpty ? "day" : "week"
        case "every", "window": return "day"
        default: return "once"
        }
    }

    static func isDone(_ t: [String: Any]) -> Bool {
        guard let doneOn = t["done_on"] as? String else { return false }
        let today = LocalRooms.today()
        switch period(t) {
        case "once": return true
        case "day": return doneOn == today
        default:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: doneOn) else { return false }
            return Calendar(identifier: .iso8601).isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
        }
    }

    static func describeWhen(_ shape: String?, _ spec: [String: Any], zh: Bool) -> String {
        switch shape {
        case "once":
            let d = LocalStore.date(spec["at"])
            let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
            return String(format: "%d/%d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        case "at":
            let time = spec["time"] as? String ?? ""
            let days = spec["days"] as? [Int] ?? []
            if days.isEmpty { return zh ? "每天 \(time)" : "Daily \(time)" }
            let names = zh ? Array("一二三四五六日").map(String.init) : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let list = days.compactMap { names.indices.contains($0) ? names[$0] : nil }.joined(separator: zh ? "、" : ", ")
            return zh ? "每周\(list) \(time)" : "\(list) \(time)"
        case "every": return zh ? "每隔 \(spec["every_min"] ?? "") 分钟" : "Every \(spec["every_min"] ?? "") min"
        case "window": return zh ? "每天 \(spec["from"] ?? "")～\(spec["to"] ?? "") 之间" : "Daily between \(spec["from"] ?? "") and \(spec["to"] ?? "")"
        default: return ""
        }
    }

    static func todoOut(_ host: LocalHost, _ t: [String: Any]) -> [String: Any] {
        let cid = t["companion_id"] as? String ?? ""
        let comp = host.store.companion(cid)
        let zh = ((comp?["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        let place = (t["place_id"] as? Int).flatMap { pid in host.store.collection("places").first { ($0["id"] as? Int) == pid } }
        return ["id": t["id"] ?? 0, "what": t["what"] ?? "", "companion_id": cid,
                "companion": (comp?["persona"] as? [String: Any])?["name"] ?? "", "shape": t["shape"] ?? NSNull(),
                "spec": t["spec"] ?? [String: Any](), "when": describeWhen(t["shape"] as? String, t["spec"] as? [String: Any] ?? [:], zh: zh),
                "place_id": t["place_id"] ?? NSNull(), "place": place?["name"] ?? NSNull(), "place_on": t["place_on"] ?? NSNull(),
                "repeat": period(t), "done": isDone(t), "created_by": t["created_by"] ?? "user"]
    }

    static func addTodo(_ host: LocalHost, _ b: [String: Any]) -> LocalResponse {
        let what = (b["what"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !what.isEmpty else { return .error(400, String(localized: "写一下要做什么")) }
        let cid = (b["companion_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (host.store.companions.first?["id"] as? String ?? "")
        let t: [String: Any] = ["id": host.store.nextID("todo"), "what": String(what.prefix(100)), "companion_id": cid,
                                "shape": b["shape"] ?? NSNull(), "spec": b["spec"] ?? [String: Any](),
                                "place_id": b["place_id"] ?? NSNull(), "place_on": b["place_on"] ?? NSNull(),
                                "created_by": "user", "created_at": LocalStore.iso(Date())]
        host.store.saveCollection("todos", host.store.collection("todos") + [t])
        Reminders.schedule(todoOut(host, t), raw: t)
        return .json(todoOut(host, t), status: 201)
    }

    static func patchTodo(_ host: LocalHost, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = host.store.collection("todos")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这条待办")) }
        for k in ["what", "shape", "spec", "place_id", "place_on", "companion_id"] where b.keys.contains(k) { all[i][k] = b[k] ?? NSNull() }
        host.store.saveCollection("todos", all)
        Reminders.schedule(todoOut(host, all[i]), raw: all[i])
        return .json(todoOut(host, all[i]))
    }

    static func doneTodo(_ host: LocalHost, _ id: Int?, _ done: Bool) -> LocalResponse {
        var all = host.store.collection("todos")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这条待办")) }
        all[i]["done_on"] = done ? LocalRooms.today() : NSNull()
        host.store.saveCollection("todos", all)
        if done && period(all[i]) == "once" { Reminders.cancel(todo: id) }
        return .json(todoOut(host, all[i]))
    }

    static func addPlace(_ s: LocalStore, _ b: [String: Any]) -> LocalResponse {
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let lat = b["lat"] as? Double, let lon = b["lon"] as? Double else {
            return .error(400, String(localized: "要有名字和位置"))
        }
        let p: [String: Any] = ["id": s.nextID("place"), "name": String(name.prefix(20)), "lat": lat, "lon": lon,
                                "radius": min(1000, max(100, b["radius"] as? Int ?? 150)), "inside": NSNull()]
        s.saveCollection("places", s.collection("places") + [p])
        return .json(p, status: 201)
    }

    /// 地理围栏进出：记下在不在；有「到了 / 离开时提醒」的待办就当场弹一条本地提醒
    static func placeEvent(_ host: LocalHost, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = host.store.collection("places")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这个地方")) }
        let inside = b["inside"] as? Bool ?? false
        all[i]["inside"] = inside
        host.store.saveCollection("places", all)
        var fired = 0
        if !(b["sync"] as? Bool ?? false) {
            for t in host.store.collection("todos") where (t["place_id"] as? Int) == id && !isDone(t) {
                let want = (t["place_on"] as? String ?? "arrive") == "arrive"
                if want == inside {
                    Reminders.fireNow(todoOut(host, t))
                    fired += 1
                }
            }
        }
        return .json(["reminding": fired > 0])
    }

    // MARK: - 钱包（金额存「分」，照 brain/wallet.py）

    static let defaultOut = ["吃饭", "交通", "购物", "娱乐", "学习", "其他"]
    static let defaultIn = ["零花钱", "打工", "红包", "其他收入"]
    static let currencies = ["AUD": "A$", "CNY": "¥", "USD": "US$", "EUR": "€", "GBP": "£", "JPY": "¥", "HKD": "HK$", "NZD": "NZ$"]

    static func cents(_ v: Any?) -> Int? {
        let s = "\(v ?? "")".replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Double(s), d > 0, d < 10_000_000 else { return nil }
        return Int((d * 100).rounded())
    }

    static func walletSettings(_ s: LocalStore) -> [String: Any] {
        let w = s.read("wallet-settings.json") as? [String: Any] ?? [:]
        let cur = w["currency"] as? String ?? (Locale.current.currency?.identifier ?? "AUD")
        let custom = w["custom"] as? [String: [String]] ?? ["out": [], "in": []]
        return ["currency": cur, "symbol": currencies[cur] ?? cur, "budget": w["budget"] ?? 0,
                "categories": defaultOut + (custom["out"] ?? []).filter { !defaultOut.contains($0) },
                "income_categories": defaultIn + (custom["in"] ?? []).filter { !defaultIn.contains($0) },
                "custom": custom]
    }

    static func walletSaveSettings(_ s: LocalStore, _ b: [String: Any]) -> LocalResponse {
        var w = s.read("wallet-settings.json") as? [String: Any] ?? [:]
        if let c = b["currency"] as? String {
            guard currencies[c.uppercased()] != nil else { return .error(400, String(localized: "这个币种还不认")) }
            w["currency"] = c.uppercased()
        }
        if b.keys.contains("budget") { w["budget"] = ["0", ""].contains("\(b["budget"] ?? "")") ? 0 : (cents(b["budget"]) ?? 0) }
        if let c = b["custom"] as? [String: [String]] { w["custom"] = c }
        s.write("wallet-settings.json", w)
        return .json(walletSettings(s))
    }

    static func rememberTag(_ s: LocalStore, kind: String, _ tag: String) {
        var w = s.read("wallet-settings.json") as? [String: Any] ?? [:]
        var custom = w["custom"] as? [String: [String]] ?? ["out": [], "in": []]
        let defaults = kind == "out" ? defaultOut : defaultIn
        if !defaults.contains(tag), !(custom[kind] ?? []).contains(tag) { custom[kind, default: []].append(tag) }
        w["custom"] = custom
        s.write("wallet-settings.json", w)
    }

    static func walletAdd(_ s: LocalStore, _ b: [String: Any]) -> LocalResponse {
        let kind = b["kind"] as? String ?? "out"
        guard ["out", "in"].contains(kind) else { return .error(400, String(localized: "只能是支出（out）或收入（in）")) }
        guard let n = cents(b["amount"]) else { return .error(400, String(localized: "金额写成数字，比如 6.5")) }
        let tag = String((b["category"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(12))
        let category = tag.isEmpty ? (kind == "out" ? "其他" : "其他收入") : tag
        rememberTag(s, kind: kind, category)
        let e: [String: Any] = ["id": s.nextID("wallet"), "kind": kind, "amount": n, "category": category,
                                "note": String((b["note"] as? String ?? "").prefix(200)),
                                "day": (b["day"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? LocalRooms.today(),
                                "author": "user", "created_at": LocalStore.iso(Date())]
        s.saveCollection("wallet", s.collection("wallet") + [e])
        return .json(e, status: 201)
    }

    static func walletUpdate(_ s: LocalStore, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = s.collection("wallet")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这一笔")) }
        if b["amount"] != nil {
            guard let n = cents(b["amount"]) else { return .error(400, String(localized: "金额写成数字，比如 6.5")) }
            all[i]["amount"] = n
        }
        if let c = b["category"] as? String, !c.isEmpty { all[i]["category"] = c; rememberTag(s, kind: all[i]["kind"] as? String ?? "out", c) }
        if let n = b["note"] as? String { all[i]["note"] = n }
        if let d = b["day"] as? String, !d.isEmpty { all[i]["day"] = d }
        s.saveCollection("wallet", all)
        return .json(all[i])
    }

    static func walletMonth(_ s: LocalStore, _ month: String) -> [String: Any] {
        let m = month.isEmpty ? String(LocalRooms.today().prefix(7)) : month
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        let prev = f.date(from: m).flatMap { Calendar.current.date(byAdding: .month, value: -1, to: $0) }.map { f.string(from: $0) } ?? ""
        let all = s.collection("wallet")
        let rows = all.filter { ($0["day"] as? String ?? "").hasPrefix(m) }
            .sorted { ($0["day"] as? String ?? "", $0["id"] as? Int ?? 0) > ($1["day"] as? String ?? "", $1["id"] as? Int ?? 0) }
        let last = all.filter { ($0["day"] as? String ?? "").hasPrefix(prev) && ($0["kind"] as? String) == "out" }
            .reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }
        var by: [String: [String: Int]] = ["out": [:], "in": [:]]
        for r in rows { by[r["kind"] as? String ?? "out", default: [:]][r["category"] as? String ?? "", default: 0] += r["amount"] as? Int ?? 0 }
        let out = by["out"]!.values.reduce(0, +), inc = by["in"]!.values.reduce(0, +)
        func ranked(_ d: [String: Int]) -> [[Any]] { d.sorted { $0.value > $1.value }.map { [$0.key, $0.value] } }
        var res: [String: Any] = ["month": m, "total": out, "income": inc, "net": inc - out, "last_month": last,
                                  "by_category": ranked(by["out"]!), "by_income": ranked(by["in"]!), "entries": rows]
        for (k, v) in walletSettings(s) { res[k] = v }
        return res
    }

    static func walletReceipt(_ s: LocalStore, _ day: String) -> [String: Any] {
        let all = s.collection("wallet")
        let rows = all.filter { ($0["day"] as? String) == day }.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        let out = rows.filter { ($0["kind"] as? String) == "out" }.reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }
        let inc = rows.filter { ($0["kind"] as? String) == "in" }.reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }
        let no = Set(all.compactMap { $0["day"] as? String }.filter { $0 <= day }).count
        let st = walletSettings(s)
        return ["day": day, "no": no, "entries": rows, "out": out, "income": inc, "net": inc - out,
                "currency": st["currency"] ?? "AUD", "symbol": st["symbol"] ?? "A$"]
    }
}

/// 待办的提醒：Lite 没有服务器推送，到点用手机本地提醒（「TA：该做 X 了」）
enum Reminders {
    static func id(_ todo: Int) -> String { "todo-\(todo)" }

    static func cancel(todo: Int) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: (0...7).map { "\(id(todo))-\($0)" })
    }

    private static func content(_ t: [String: Any]) -> UNMutableNotificationContent {
        let n = UNMutableNotificationContent()
        n.title = t["companion"] as? String ?? "Mele"
        n.body = String(localized: "提醒你：\(t["what"] as? String ?? "")")
        n.sound = .default
        return n
    }

    static func schedule(_ t: [String: Any], raw: [String: Any]) {
        guard let tid = t["id"] as? Int else { return }
        cancel(todo: tid)
        let spec = raw["spec"] as? [String: Any] ?? [:]
        var triggers: [UNNotificationTrigger] = []
        switch raw["shape"] as? String {
        case "once":
            let d = LocalStore.date(spec["at"])
            guard d > Date() else { return }
            triggers = [UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d), repeats: false)]
        case "at":
            let hm = (spec["time"] as? String ?? "").split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2 else { return }
            let days = spec["days"] as? [Int] ?? []
            if days.isEmpty {
                triggers = [UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hm[0], minute: hm[1]), repeats: true)]
            } else {
                triggers = days.map { UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hm[0], minute: hm[1], weekday: ($0 + 1) % 7 + 1), repeats: true) }
            }
        default: return
        }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            for (i, tr) in triggers.enumerated() {
                c.add(UNNotificationRequest(identifier: "\(id(tid))-\(i)", content: content(t), trigger: tr))
            }
        }
    }

    static func fireNow(_ t: [String: Any]) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content(t),
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
    }
}
#endif
