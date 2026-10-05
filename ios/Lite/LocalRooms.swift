#if LITE
import Foundation
import MeleLiteCore

/// 聊天以外的房间：本机能做的照服务器接口回；还没接的回 nil（LocalHost 那边变成 needs_host）。
enum LocalRooms {
    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        switch (r.method, p.first ?? "", p.count) {
        case ("GET", "lore", 1): return .json(lore(host.store, companion: r.query["companion_id"]))
        case ("POST", "lore", 1): return addLore(host.store, r.json)
        case ("PATCH", "lore", 2): return patchLore(host.store, Int(p[1]), r.json)
        case ("DELETE", "lore", 2): return deleteLore(host.store, Int(p[1]))
        // 收藏夹
        case ("GET", "favorites", 1): return .json(host.store.collection("favorites").sorted { LocalStore.date($0["saved_at"]) > LocalStore.date($1["saved_at"]) })
        case ("POST", "favorites", 1): return addFavorites(host, r.json)
        case ("DELETE", "favorites", 2): return removeWhere(host.store, "favorites", 404, String(localized: "没有这条收藏")) { ($0["id"] as? Int) == Int(p[1]) }
        case ("DELETE", "favorites", 4) where p[1] == "bubble":
            return removeWhere(host.store, "favorites", 404, String(localized: "这句没收藏")) { ($0["message_id"] as? Int) == Int(p[2]) && ($0["slot"] as? Int) == Int(p[3]) }
        case ("DELETE", "favorites", 3) where p[1] == "group":
            return removeWhere(host.store, "favorites", 404, String(localized: "没有这组")) { ($0["group_id"] as? String) == p[2] }
        // 人物卡
        case ("GET", "people", 1): return .json(host.store.collection("people"))
        case ("POST", "people", 1): return addPerson(host.store, r.json)
        case ("PATCH", "people", 2): return patchItem(host.store, "people", Int(p[1]), r.json,
                                                       keys: ["name", "aliases", "relation", "facts", "impression", "hidden_from"])
        case ("DELETE", "people", 2): return removeWhere(host.store, "people", 404, String(localized: "没有这张卡")) { ($0["id"] as? Int) == Int(p[1]) }
        // 它记着的事（远事）
        case ("GET", "companions", 3) where p[2] == "dates": return .json(dates(host.store, companion: p[1]))
        case ("POST", "companions", 3) where p[2] == "dates": return addDate(host.store, companion: p[1], r.json)
        case ("PATCH", "dates", 2): return patchDate(host.store, Int(p[1]), r.json)
        case ("DELETE", "dates", 2): return removeWhere(host.store, "dates", 404, String(localized: "没有这件")) { ($0["id"] as? Int) == Int(p[1]) }
        // 日记（Lite 只有你自己那本；它的日记要半夜醒来写，要 Mele Host）
        case ("GET", "diary", 1): return .json(host.store.collection("diary").sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") })
        case ("POST", "diary", 1): return writeDiary(host.store, r.json)
        case ("PATCH", "diary", 2): return patchDiary(host.store, Int(p[1]), r.json)
        case ("DELETE", "diary", 2): return removeWhere(host.store, "diary", 404, String(localized: "没有这篇")) { ($0["id"] as? Int) == Int(p[1]) }
        case ("POST", "diary", 3) where p[2] == "unlock": return .error(409, String(localized: "这篇没有锁着的段"))
        // 里程碑（它在聊天里立的）
        case ("GET", "milestones", 1): return .json(host.store.collection("milestones"))
        // 抽屉（它的信：打开 App 时它可能留了一封）
        case ("GET", "drawer", 1): return .json(drawer(host.store))
        case ("POST", "drawer", 3) where p[2] == "open": return openLetter(host.store, Int(p[1]))
        default: return LocalRooms2.handle(r, host: host)
        }
    }

    // MARK: 世界书（照 server/api/routes_lore.py）

    static func loreOut(_ e: MeleLiteCore.LoreEntry, companion: String?, id: Int) -> [String: Any] {
        ["id": id, "companion_id": companion ?? NSNull(), "name": e.title, "keywords": e.keys, "content": e.content,
         "created_by": "user", "enabled": e.enabled, "constant": e.constant, "updated_at": LocalStore.iso(Date())]
    }

    static func lore(_ s: LocalStore, companion: String?) -> [[String: Any]] {
        let all = s.collection("lore")
        guard let companion, !companion.isEmpty else { return all }
        return all.filter { ($0["companion_id"] as? String).map { $0 == companion } ?? true }
    }

    /// 给提示词用：这个联系人看得到的（它的 + 共享的）
    static func loreEntries(_ s: LocalStore, companion: String) -> [MeleLiteCore.LoreEntry] {
        lore(s, companion: companion).map {
            var e = MeleLiteCore.LoreEntry(title: $0["name"] as? String ?? "", keys: $0["keywords"] as? [String] ?? [],
                              content: $0["content"] as? String ?? "")
            e.constant = $0["constant"] as? Bool ?? false
            e.enabled = $0["enabled"] as? Bool ?? true
            return e
        }
    }

    static func keywords(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let s = v as? String ?? ""
        return s.split(whereSeparator: { ",，、\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func addLore(_ s: LocalStore, _ b: [String: Any]) -> LocalResponse {
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let content = (b["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return .error(400, String(localized: "内容不能空着")) }
        let cid = (b["companion_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let e: [String: Any] = ["id": s.nextID("lore"), "companion_id": cid ?? NSNull(), "name": name.isEmpty ? String(content.prefix(12)) : name,
                                "keywords": keywords(b["keywords"]), "content": content, "created_by": "user",
                                "enabled": b["enabled"] as? Bool ?? true, "constant": b["constant"] as? Bool ?? false,
                                "updated_at": LocalStore.iso(Date())]
        s.saveCollection("lore", s.collection("lore") + [e])
        return .json(e, status: 201)
    }

    static func patchLore(_ s: LocalStore, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = s.collection("lore")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这一条")) }
        for k in ["name", "content", "enabled", "constant"] where b[k] != nil { all[i][k] = b[k] }
        if b["keywords"] != nil { all[i]["keywords"] = keywords(b["keywords"]) }
        if b.keys.contains("companion_id") { all[i]["companion_id"] = (b["companion_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSNull() }
        all[i]["updated_at"] = LocalStore.iso(Date())
        s.saveCollection("lore", all)
        return .json(all[i])
    }

    static func deleteLore(_ s: LocalStore, _ id: Int?) -> LocalResponse {
        let all = s.collection("lore")
        guard let id, all.contains(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这一条")) }
        s.saveCollection("lore", all.filter { ($0["id"] as? Int) != id })
        return .empty
    }

    // MARK: 通用

    static func removeWhere(_ s: LocalStore, _ name: String, _ status: Int, _ msg: String,
                            _ match: ([String: Any]) -> Bool) -> LocalResponse {
        let all = s.collection(name)
        let kept = all.filter { !match($0) }
        guard kept.count < all.count else { return .error(status, msg) }
        s.saveCollection(name, kept)
        return .empty
    }

    static func patchItem(_ s: LocalStore, _ name: String, _ id: Int?, _ b: [String: Any], keys: [String]) -> LocalResponse {
        var all = s.collection(name)
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这一条")) }
        for k in keys where b.keys.contains(k) { all[i][k] = b[k] }
        all[i]["updated_at"] = LocalStore.iso(Date())
        all[i]["updated_by"] = keys.contains("updated_by") ? (b["updated_by"] ?? "user") : "user"   // TA 的工具会自己带 ai
        s.saveCollection(name, all)
        return .json(all[i])
    }

    static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: Date())
    }

    // MARK: 收藏夹（照 brain/favorites.py）

    static func addFavorites(_ host: LocalHost, _ b: [String: Any]) -> LocalResponse {
        let items = b["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { return .error(400, String(localized: "要收哪句？")) }
        let gid = (b["group"] as? Bool ?? false) && items.count > 1 ? UUID().uuidString.lowercased() : nil
        var all = host.store.collection("favorites")
        var out: [[String: Any]] = []
        for it in items {
            guard let mid = it["message_id"] as? Int, let (conv, idx) = host.store.locate(message: mid) else {
                return .error(400, String(localized: "没有这句"))
            }
            let slot = it["slot"] as? Int ?? 0
            if all.contains(where: { ($0["message_id"] as? Int) == mid && ($0["slot"] as? Int) == slot }) { continue }
            let m = host.store.messages(conv)[idx]
            let comp = host.store.conversation(conv)?["companion_id"] as? String ?? ""
            let files = (it["with_files"] as? Bool ?? false) ? (m["attachments"] as? [String] ?? []).compactMap { host.attachmentPublic($0) } : []
            let f: [String: Any] = ["id": host.store.nextID("favorite"), "companion_id": comp, "conversation_id": conv,
                                    "message_id": mid, "slot": slot, "mine": (m["role"] as? String) == "user",
                                    "text": String((it["text"] as? String ?? "").prefix(4000)), "files": files,
                                    "group_id": gid ?? NSNull(), "said_at": m["at"] ?? LocalStore.iso(Date()),
                                    "saved_at": LocalStore.iso(Date())]
            all.append(f)
            out.append(f)
        }
        host.store.saveCollection("favorites", all)
        return .json(out, status: 201)
    }

    // MARK: 人物卡

    static func addPerson(_ s: LocalStore, _ b: [String: Any]) -> LocalResponse {
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .error(400, String(localized: "名字是空的")) }
        let all = s.collection("people")
        if all.contains(where: { ($0["name"] as? String ?? "").lowercased() == name.lowercased() }) {
            return .error(409, String(localized: "已经有这个人了，去改那张卡"))
        }
        let p: [String: Any] = ["id": s.nextID("person"), "name": name, "aliases": b["aliases"] ?? [String](),
                                "relation": b["relation"] ?? "", "facts": b["facts"] ?? "", "impression": b["impression"] ?? "",
                                "created_by": "user", "updated_by": "user", "updated_at": LocalStore.iso(Date()),
                                "hidden_from": b["hidden_from"] ?? [String]()]
        s.saveCollection("people", all + [p])
        return .json(p, status: 201)
    }

    // MARK: 它记着的事（照 routes_dates.py：只列没了结的）

    static func dateOut(_ d: [String: Any]) -> [String: Any] {
        var o = d
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        if let day = f.date(from: d["day"] as? String ?? ""), let t = f.date(from: today()) {
            o["days_left"] = Calendar.current.dateComponents([.day], from: t, to: day).day ?? 0
        }
        return o
    }

    static func dates(_ s: LocalStore, companion: String) -> [[String: Any]] {
        s.collection("dates").filter { ($0["companion_id"] as? String) == companion && $0["moved_to"] == nil }   // 搬去记忆库的收起来
            .sorted { ($0["day"] as? String ?? "") < ($1["day"] as? String ?? "") }.map(dateOut)
    }

    static func addDate(_ s: LocalStore, companion: String, _ b: [String: Any]) -> LocalResponse {
        let title = (b["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return .error(400, String(localized: "写一下是什么事")) }
        guard let day = b["day"] as? String, day.count == 10 else { return .error(400, "day 要写成 YYYY-MM-DD") }
        let d: [String: Any] = ["id": s.nextID("date"), "companion_id": companion, "day": day, "time": b["time"] as? String ?? "",
                                "title": title, "note": b["note"] as? String ?? ""]
        s.saveCollection("dates", s.collection("dates") + [d])
        return .json(dateOut(d), status: 201)
    }

    static func patchDate(_ s: LocalStore, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = s.collection("dates")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这件")) }
        for k in ["day", "time", "title", "note"] where b.keys.contains(k) { all[i][k] = b[k] as? String ?? "" }
        s.saveCollection("dates", all)
        return .json(dateOut(all[i]))
    }

    // MARK: 日记（你的那本）

    static func writeDiary(_ s: LocalStore, _ b: [String: Any]) -> LocalResponse {
        let body = (b["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .error(400, String(localized: "写点什么吧")) }
        let now = LocalStore.iso(Date())
        let e: [String: Any] = ["id": s.nextID("diary"), "author": "user", "day": b["day"] as? String ?? today(), "body": body,
                                "private": b["private"] as? Bool ?? false, "margin": "", "margin_from": NSNull(),
                                "written_at": now, "updated_at": now]
        s.saveCollection("diary", s.collection("diary") + [e])
        return .json(e)
    }

    static func patchDiary(_ s: LocalStore, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        var all = s.collection("diary")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这篇")) }
        for k in ["body", "private", "day"] where b.keys.contains(k) { all[i][k] = b[k] }
        all[i]["updated_at"] = LocalStore.iso(Date())
        s.saveCollection("diary", all)
        return .json(all[i])
    }

    // MARK: 抽屉

    static func drawer(_ s: LocalStore) -> [[String: Any]] {
        s.collection("drawer").sorted { LocalStore.date($0["written_at"]) > LocalStore.date($1["written_at"]) }.map { l in
            var o: [String: Any] = ["id": l["id"] ?? 0, "companion_id": l["companion_id"] ?? "", "from": l["from"] ?? "",
                                    "written_at": l["written_at"] ?? "", "unlock_at": NSNull(), "openable": true,
                                    "opened": l["opened_at"] != nil && !(l["opened_at"] is NSNull)]
            if o["opened"] as? Bool == true { o["title"] = l["title"] ?? "" }
            return o
        }
    }

    static func openLetter(_ s: LocalStore, _ id: Int?) -> LocalResponse {
        var all = s.collection("drawer")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return .error(404, String(localized: "没有这封")) }
        if all[i]["opened_at"] == nil || all[i]["opened_at"] is NSNull { all[i]["opened_at"] = LocalStore.iso(Date()) }
        // 早先存下的信里可能留着《里程碑：…》这类标记：拆开时顺手洗掉（里程碑那时已经没记，这里不补）
        all[i]["content"] = LocalBrain.cleanLetter(all[i]["content"] as? String ?? "").0
        s.saveCollection("drawer", all)
        let l = all[i]
        return .json(["id": id, "companion_id": l["companion_id"] ?? "", "from": l["from"] ?? "", "title": l["title"] ?? "",
                      "content": l["content"] ?? "", "written_at": l["written_at"] ?? "", "unlock_at": NSNull(),
                      "opened_at": l["opened_at"] ?? ""])
    }

    // MARK: 表情包

    static func stickersForPrompt(_ s: LocalStore) -> [Sticker] {
        s.collection("stickers").compactMap { d in
            guard let id = d["id"] as? Int, let cap = d["caption"] as? String, !cap.isEmpty else { return nil }
            return Sticker(id: String(id), sha: d["sha"] as? String ?? "", file: d["file"] as? String ?? "", caption: cap)
        }
    }

    static func matchSticker(_ s: LocalStore, _ wanted: String) -> Int? {
        let w = wanted.trimmingCharacters(in: .whitespaces)
        let all = s.collection("stickers")
        if let hit = all.first(where: { ($0["caption"] as? String) == w }) { return hit["id"] as? Int }
        return all.first(where: { ($0["caption"] as? String ?? "").contains(w) || w.contains($0["caption"] as? String ?? "\u{0}") })?["id"] as? Int
    }

    // MARK: 里程碑

    static func addMilestone(_ s: LocalStore, companion: String, title: String) {
        s.saveCollection("milestones", s.collection("milestones") + [["id": s.nextID("milestone"), "companion_id": companion,
                                                                        "title": title, "at": LocalStore.iso(Date())]])
    }
}
#endif
