#if LITE
import Foundation
import MeleLiteCore

/// 地图 + 它的一天（10-04 Tilia定 B，设计 specs/2026-10-03-mele-lite-design.md 末尾）。
/// - 每个人有自己的世界：用你的 key 照人设 + 世界书起 6～8 个地方（名字 / 一句描述 / 固定图标集里挑一个），永远有一个「家」。
/// - 它的一天：每天第一次进这个人的聊天（或打开地图），排今天几点在哪、在干嘛，只从它自己的地方里挑。
///   聊天时每轮给一行〔现在〕；地图上它在的地方点进去 = 在那儿进线下，开场是它正在做的事。
/// 存：rooms/world.json（地方）、rooms/days.json（每人每天一份行程）
enum LocalMap {
    /// 地方能用的图标（界面那份在 MapView，名字一致）
    static let icons = ["home", "cafe", "library", "office", "park", "shop", "restaurant", "gym", "music", "studio",
                        "school", "hospital", "beach", "mountain", "station", "bar", "temple", "garden"]

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts, s = host.store
        guard p.first == "world" else { return nil }
        switch (r.method, p.count) {
        case ("GET", 2):                                   // world/{companion}：地方 + 今天 + 此刻
            return .json(snapshot(s, companion: p[1]))
        case ("POST", 3) where p[2] == "generate":          // world/{companion}/generate：起世界（花你的 key）
            let cid = p[1]
            guard let comp = s.companion(cid) else { return .error(404, String(localized: "没有这个联系人")) }
            Task { _ = await ensureWorld(host, comp, force: true); _ = await ensureDay(host, cid) }
            return .json(["started": true], status: 202)
        case ("POST", 3) where p[2] == "places":           // 加一个地方
            let name = (r.json["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .error(400, String(localized: "给这个地方起个名字")) }
            var all = s.collection("world")
            let mine = all.filter { ($0["companion_id"] as? String) == p[1] }
            let pl: [String: Any] = ["id": s.nextID("place"), "companion_id": p[1], "name": String(name.prefix(16)),
                                     "desc": String((r.json["desc"] as? String ?? "").prefix(60)),
                                     "icon": icons.contains(r.json["icon"] as? String ?? "") ? r.json["icon"]! : "park",
                                     "slot": freeSlot(mine), "home": false, "by": "user"]
            all.append(pl)
            s.saveCollection("world", all)
            return .json(pl, status: 201)
        case ("PATCH", 4) where p[2] == "places":
            var all = s.collection("world")
            guard let i = all.firstIndex(where: { "\($0["id"] ?? "")" == p[3] }) else { return .error(404, String(localized: "没有这个地方")) }
            if let n = r.json["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty { all[i]["name"] = String(n.prefix(16)) }
            if let d = r.json["desc"] as? String { all[i]["desc"] = String(d.prefix(60)) }
            if let ic = r.json["icon"] as? String, icons.contains(ic) { all[i]["icon"] = ic }
            s.saveCollection("world", all)
            return .json(all[i])
        case ("DELETE", 4) where p[2] == "places":
            var all = s.collection("world")
            guard let pl = all.first(where: { "\($0["id"] ?? "")" == p[3] }) else { return .empty }
            if pl["home"] as? Bool == true { return .error(400, String(localized: "家不能删")) }
            all.removeAll { "\($0["id"] ?? "")" == p[3] }
            s.saveCollection("world", all)
            return .empty
        case ("POST", 3) where p[2] == "visit":            // 去它在的地方找它：切线下、它先开场
            return visit(host, companion: p[1], place: r.json["place_id"] as? Int)
        default:
            return nil
        }
    }

    // MARK: 读

    static func places(_ s: LocalStore, _ cid: String) -> [[String: Any]] {
        s.collection("world").filter { ($0["companion_id"] as? String) == cid }.sorted { ($0["slot"] as? Int ?? 0) < ($1["slot"] as? Int ?? 0) }
    }

    static func today(_ s: LocalStore, _ cid: String) -> [[String: Any]] {
        let day = LocalRooms.today()
        return (s.collection("days").first { ($0["companion_id"] as? String) == cid && ($0["day"] as? String) == day }?["items"]
                as? [[String: Any]]) ?? []
    }

    /// 此刻：今天行程里时间 ≤ 现在的最后一条（还没到第一条 = 第一条之前在家）
    static func now(_ s: LocalStore, _ cid: String) -> [String: Any]? {
        let items = today(s, cid)
        guard !items.isEmpty else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let hm = f.string(from: Date())
        if let cur = items.last(where: { ($0["time"] as? String ?? "") <= hm }) { return cur }
        if let home = places(s, cid).first(where: { $0["home"] as? Bool == true }) {
            return ["time": "", "place_id": home["id"] ?? 0, "doing": "", "place": home["name"] ?? ""]
        }
        return nil
    }

    static func snapshot(_ s: LocalStore, companion cid: String) -> [String: Any] {
        let pls = places(s, cid)
        let names = Dictionary(pls.map { ($0["id"] as? Int ?? 0, $0["name"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
        let items = today(s, cid).map { it -> [String: Any] in
            var o = it
            o["place"] = names[it["place_id"] as? Int ?? 0] ?? ""
            return o
        }
        var out: [String: Any] = ["places": pls, "today": items, "generating": generating.withLock { $0.contains(cid) }]
        if var n = now(s, cid) {
            n["place"] = names[n["place_id"] as? Int ?? 0] ?? n["place"] ?? ""
            out["now"] = n
        }
        return out
    }

    /// 聊天每轮给的那一行（没排行程就不给）
    static func nowLine(_ s: LocalStore, companion cid: String, zh: Bool) -> String {
        // 从地图上找过去的那场线下还没结束：你们一起在那儿，不跟行程走
        let st = s.companion(cid)?["settings"] as? [String: Any] ?? [:]
        if st["long_mode"] as? Bool == true, let pid = st["scene_place"] as? Int,
           let pl = places(s, cid).first(where: { ($0["id"] as? Int) == pid }) {
            let name = pl["name"] as? String ?? ""
            return zh ? "〔现在〕线下：你和 TA 一起在「\(name)」。今天原本的安排先放一边，照着眼前说。"
                      : "[Right now] In person: you and them are together at \"\(name)\". Set today's plan aside; stay in this scene."
        }
        guard let n = now(s, cid) else { return "" }
        let place = places(s, cid).first { ($0["id"] as? Int) == (n["place_id"] as? Int) }
        let name = place?["name"] as? String ?? ""
        let doing = n["doing"] as? String ?? ""
        guard !name.isEmpty else { return "" }
        let rest = today(s, cid).filter { ($0["time"] as? String ?? "") > (n["time"] as? String ?? "") }
            .prefix(2).map { "\($0["time"] as? String ?? "") \($0["doing"] as? String ?? "")" }.joined(separator: "；")
        return zh
            ? "〔现在〕你在「\(name)」\(doing.isEmpty ? "" : "，\(doing)")。\(rest.isEmpty ? "" : "今天接下来：\(rest)。")照这个说，不用特意提。"
            : "[Right now] You're at \"\(name)\"\(doing.isEmpty ? "" : ", \(doing)"). \(rest.isEmpty ? "" : "Later today: \(rest). ")Stay consistent with this; no need to announce it."
    }

    // MARK: 起世界、排一天（用你的 key）

    /// 正在起世界 / 排行程的（同一个人别并发跑两次）
    private final class Busy: @unchecked Sendable {
        private let lock = NSLock()
        private var set: Set<String> = []
        func withLock<T>(_ f: (inout Set<String>) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(&set) }
    }
    private static let generating = Busy()

    @discardableResult
    static func ensureWorld(_ host: LocalHost, _ comp: [String: Any], force: Bool = false) async -> Bool {
        let s = host.store
        guard let cid = comp["id"] as? String else { return false }
        if !force, !places(s, cid).isEmpty { return true }
        guard let (provider, key) = host.route(for: comp), !LiteConsent.book.needsAsk(provider) else { return false }
        guard generating.withLock({ $0.insert(cid).inserted }) else { return false }
        defer { generating.withLock { _ = $0.remove(cid) } }
        let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        let contact = LocalBrain.contact(comp, provider: provider)
        let lore = LocalRooms.loreEntries(s, companion: cid).prefix(8).map { "\($0.title)：\($0.content.prefix(120))" }.joined(separator: "\n")
        let ask = zh
            ? "照你自己的人设和世界，列出你生活里常去的 6～8 个地方。第一个必须是你的家。每行一个，格式：\n名字｜一句描述（15 字内）｜图标\n图标只能从这些里挑：\(icons.joined(separator: ", "))\n只写这几行，不要别的。\(lore.isEmpty ? "" : "\n\n世界书里写过的：\n\(lore)")"
            : "Based on who you are and your world, list 6-8 places you often go. The first must be your home. One per line:\nName | one-line description (under 10 words) | icon\nIcon must be one of: \(icons.joined(separator: ", "))\nOnly these lines.\(lore.isEmpty ? "" : "\n\nFrom the lorebook:\n\(lore)")"
        var req = Prompt.build(PromptInput(contact: contact, identity: contact.mainIdentity, history: [], lang: zh ? .zh : .en))
        req.turns = [ChatTurn(role: .user, text: ask)]
        req.maxTokens = 800
        var text = ""
        do { for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { return false }
        var made: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            let bits = line.split(whereSeparator: { $0 == "｜" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bits.count >= 2, !bits[0].isEmpty else { continue }
            let name = bits[0].trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. 、"))
            guard !name.isEmpty else { continue }
            let icon = bits.count >= 3 && icons.contains(bits[2].lowercased()) ? bits[2].lowercased() : (made.isEmpty ? "home" : "park")
            made.append(["id": s.nextID("place"), "companion_id": cid, "name": String(name.prefix(16)), "desc": String(bits[1].prefix(60)),
                         "icon": made.isEmpty ? "home" : icon, "slot": made.count, "home": made.isEmpty, "by": "ai"])
            if made.count == 8 { break }
        }
        guard made.count >= 3 else { return false }
        // 重起世界：它起的换掉，你自己加的留着（挪到后面的空位）
        var keep = s.collection("world").filter { ($0["companion_id"] as? String) != cid || ($0["by"] as? String) == "user" }
        for i in keep.indices where (keep[i]["companion_id"] as? String) == cid {
            keep[i]["slot"] = made.count + i
        }
        s.saveCollection("world", keep + made)
        // 行程跟着旧地方的作废
        s.saveCollection("days", s.collection("days").filter { ($0["companion_id"] as? String) != cid })
        return true
    }

    /// 今天的行程：没有就排（只从它自己的地方里挑）
    @discardableResult
    static func ensureDay(_ host: LocalHost, _ cid: String) async -> Bool {
        let s = host.store
        if !today(s, cid).isEmpty { return true }
        guard let comp = s.companion(cid) else { return false }
        guard await ensureWorld(host, comp) else { return false }
        let pls = places(s, cid)
        guard !pls.isEmpty, let (provider, key) = host.route(for: comp), !LiteConsent.book.needsAsk(provider) else { return false }
        let busyKey = cid + "#day"
        guard generating.withLock({ $0.insert(busyKey).inserted }) else { return false }
        defer { generating.withLock { _ = $0.remove(busyKey) } }
        let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        let contact = LocalBrain.contact(comp, provider: provider)
        let list = pls.map { "\($0["name"] as? String ?? "")（\($0["desc"] as? String ?? "")）" }.joined(separator: "\n")
        let f = DateFormatter(); f.dateFormat = zh ? "yyyy-MM-dd EEEE" : "EEEE, d MMM"
        f.locale = Locale(identifier: zh ? "zh_CN" : "en_US")
        let ask = zh
            ? "今天是 \(f.string(from: Date()))。排一下你今天的一天：从起床到睡觉 5～8 段，只能去这些地方：\n\(list)\n每行一段，格式：\nHH:MM｜地方名字｜在干嘛（12 字内）\n照你平时的样子排，按时间顺序，只写这几行。"
            : "Today is \(f.string(from: Date())). Plan your day from waking up to bed in 5-8 blocks, only at these places:\n\(list)\nOne per line:\nHH:MM | place name | what you're doing (under 8 words)\nIn time order, only these lines."
        var req = Prompt.build(PromptInput(contact: contact, identity: contact.mainIdentity, history: [], lang: zh ? .zh : .en))
        req.turns = [ChatTurn(role: .user, text: ask)]
        req.maxTokens = 700
        var text = ""
        do { for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { return false }
        var items: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            let bits = line.split(whereSeparator: { $0 == "｜" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bits.count >= 3 else { continue }
            let hm = bits[0].filter { $0.isNumber || $0 == ":" || $0 == "：" }.replacingOccurrences(of: "：", with: ":")
            let parts = hm.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { continue }
            guard let pl = pls.first(where: { ($0["name"] as? String) == bits[1] })
                    ?? pls.first(where: { bits[1].contains($0["name"] as? String ?? "\u{0}") || ($0["name"] as? String ?? "").contains(bits[1]) }) else { continue }
            items.append(["time": String(format: "%02d:%02d", parts[0], parts[1]), "place_id": pl["id"] ?? 0, "doing": String(bits[2].prefix(30))])
        }
        guard !items.isEmpty else { return false }
        items.sort { ($0["time"] as? String ?? "") < ($1["time"] as? String ?? "") }
        let day = LocalRooms.today()
        var all = s.collection("days").filter { !(($0["companion_id"] as? String) == cid && ($0["day"] as? String) == day) }
        all.append(["companion_id": cid, "day": day, "items": items])
        // 只留最近 14 天
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let cut = Calendar.current.date(byAdding: .day, value: -14, to: Date()).map { df.string(from: $0) } ?? ""
        all = all.filter { ($0["day"] as? String ?? "") >= cut }
        s.saveCollection("days", all)
        return true
    }

    // MARK: 去找它

    private static func visit(_ host: LocalHost, companion cid: String, place: Int?) -> LocalResponse {
        let s = host.store
        guard var comp = s.companion(cid) else { return .error(404, String(localized: "没有这个联系人")) }
        let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        let pls = places(s, cid)
        let n = now(s, cid)
        let pid = place ?? (n?["place_id"] as? Int)
        guard let pl = pls.first(where: { ($0["id"] as? Int) == pid }) else { return .error(404, String(localized: "没有这个地方")) }
        // 切线下（长文）
        var st = comp["settings"] as? [String: Any] ?? [:]
        st["long_mode"] = true
        st["scene_place"] = pid           // 线下这场在哪：行程往后走了它也记得你们还在这儿
        comp["settings"] = st
        s.saveCompanion(comp)
        // 进它最近的平常窗口，没有就开一个
        let conv = (s.conversations.filter { ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) }
            .max { LocalStore.date($0["last_at"]) < LocalStore.date($1["last_at"]) }) ?? host.newConversation(cid, incognito: false)
        guard let convID = conv["id"] as? String else { return .error(500, "") }
        let isNow = (n?["place_id"] as? Int) == pid
        let doing = isNow ? (n?["doing"] as? String ?? "") : ""
        let name = pl["name"] as? String ?? ""
        let nudge = zh
            ? "（TA 来「\(name)」找你了\(doing.isEmpty ? "" : "，你这会儿正在\(doing)")。线下开场：写你在那儿正做着的事、身边的样子，然后看见 TA 来了。）"
            : "(They came to find you at \"\(name)\"\(doing.isEmpty ? "" : " while you're \(doing)"). Open the in-person scene: what you're doing there, the surroundings, then noticing them arrive.)"
        // 等聊天页推开、接上事件流再开场（不然开头几个气泡推给了没人听的流）
        Task { try? await Task.sleep(for: .seconds(1.2)); host.brain.poke(convID, nudge: nudge) }
        return .json(["conversation": convID])
    }

    private static func freeSlot(_ mine: [[String: Any]]) -> Int {
        let used = Set(mine.compactMap { $0["slot"] as? Int })
        return (0...).first { !used.contains($0) } ?? mine.count
    }
}
#endif
