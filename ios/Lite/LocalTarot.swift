#if LITE
import CryptoKit
import Foundation
import MeleLiteCore

/// 塔罗（10-04 Tilia：Lite 也要能抽牌）：照 server/api/routes_tarot.py + brain/tarot*.py 搬进手机。
/// - 牌义、牌阵、说明书从服务器那份导出来（TarotData.swift，ios/Lite/tools/gen_tarot_data.py），这边不另写。
/// - 洗牌：手机真随机 + TA 手搓的指尖轨迹定种子，整副牌序存起来（30 分钟有效）；界面只交「第几张」。正位 0.65。
/// - 谁来解：某个联系人（带人设和最近聊的几句）或解牌人（中立：不带人设、不带聊天）。解读用你自己的 key，App 开着时跑。
/// - 联系人解好的那一局，它下一次开口时递一句〔塔罗〕；它在聊天里也能自己抽（工具 tarot）。
enum LocalTarot {
    static let upright = 0.65
    static let deckTTL: TimeInterval = 30 * 60
    static let maxQuestion = 300
    static let maxText = 6000
    static let maxTries = 3

    // MARK: - 牌义 / 牌阵（从 TarotData 解出来）

    private static let data: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(TarotData.json.utf8))) as? [String: Any] ?? [:]
    static let order: [String] = data["order"] as? [String] ?? []
    private static let cards: [String: [String: [String: Any]]] = data["cards"] as? [String: [String: [String: Any]]] ?? [:]
    private static let spreadList: [[String: Any]] = data["spreads"] as? [[String: Any]] ?? []
    private static let manuals: [String: String] = data["manual"] as? [String: String] ?? [:]

    static func lang(_ zh: Bool) -> String { zh ? "zh" : "en" }

    static func name(_ key: String, zh: Bool) -> String { cards[key]?[lang(zh)]?["name"] as? String ?? key }

    static func side(_ key: String, reversed: Bool, zh: Bool) -> (core: String, keywords: [String]) {
        let s = cards[key]?[lang(zh)]?[reversed ? "reversed" : "upright"] as? [String: Any] ?? [:]
        return (s["core"] as? String ?? "", s["keywords"] as? [String] ?? [])
    }

    static func entryLine(_ key: String, reversed: Bool, zh: Bool) -> String {
        let s = side(key, reversed: reversed, zh: zh)
        if zh { return "\(name(key, zh: true))（\(reversed ? "逆位" : "正位")）：\(s.core)｜关键词：\(s.keywords.joined(separator: "、"))" }
        return "\(name(key, zh: false)) (\(reversed ? "reversed" : "upright")): \(s.core) | keywords: \(s.keywords.joined(separator: ", "))"
    }

    static func spread(_ key: String) -> [String: Any]? { spreadList.first { ($0["key"] as? String) == key } }

    static func spreadName(_ key: String, zh: Bool) -> String { (spread(key)?["name"] as? [String: String])?[lang(zh)] ?? key }

    static func positions(_ key: String, zh: Bool) -> [String] { (spread(key)?["positions"] as? [String: [String]])?[lang(zh)] ?? [] }

    static func spreadsPublic(zh: Bool) -> [[String: Any]] {
        spreadList.filter { ($0["key"] as? String) != "followup" }.map { s in
            let key = s["key"] as? String ?? ""
            return ["key": key, "name": spreadName(key, zh: zh), "usage": (s["usage"] as? [String: String])?[lang(zh)] ?? "",
                    "count": (s["layout"] as? [Any])?.count ?? 0, "positions": positions(key, zh: zh), "layout": s["layout"] ?? [],
                    "board_height": s["board_height"] ?? 0, "card_width": s["card_width"] ?? 0]
        }
    }

    static func cardsPublic(zh: Bool) -> [[String: Any]] {
        order.map { ["key": $0, "name": name($0, zh: zh), "upright": side($0, reversed: false, zh: zh).keywords,
                     "reversed": side($0, reversed: true, zh: zh).keywords] }
    }

    // MARK: - 洗牌

    /// 种子：16 字节真随机 + 指尖轨迹，SHA256 之后喂一个确定的随机数发生器（同一个种子永远洗出同一副）
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: Data) { state = seed.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } | 1 }
        mutating func next() -> UInt64 {            // SplitMix64
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func makeSeed(trail: String = "") -> String {
        var bytes = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        bytes.append(Data(String(trail.prefix(4000)).utf8))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func shuffle(seed: String) -> [[String: Any]] {
        var rng = SeededRNG(seed: Data(SHA256.hash(data: Data(seed.utf8))))
        return order.shuffled(using: &rng).map { ["card": $0, "reversed": Double.random(in: 0..<1, using: &rng) >= upright] }
    }

    // MARK: - 接口

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        guard p.first == "tarot" else { return nil }
        let s = host.store
        let zh = accountZh(host)
        let rid = p.count > 2 ? Int(p[2]) : nil
        switch (r.method, p.count) {
        case ("GET", 2) where p[1] == "spreads": return .json(spreadsPublic(zh: zh))
        case ("GET", 2) where p[1] == "cards": return .json(cardsPublic(zh: zh))
        case ("POST", 2) where p[1] == "deck":
            let seed = makeSeed(trail: r.json["trail"] as? String ?? "")
            let deck = shuffle(seed: seed)
            let id = s.nextID("tarot-deck")
            let fresh = s.collection("tarot-decks").filter { Date().timeIntervalSince(LocalStore.date($0["created_at"])) < deckTTL }
            s.saveCollection("tarot-decks", fresh + [["id": id, "seed": seed, "deck": deck, "created_at": LocalStore.iso(Date())]])
            return .json(["deck_id": id, "deck": deck], status: 201)
        case ("POST", 2) where p[1] == "readings": return create(host, r.json)
        case ("GET", 2) where p[1] == "readings":
            let comp = r.query["companion_id"]?.lowercased(), asker = r.query["asker"]
            let rows = s.collection("tarot").filter { x in
                (comp == nil || comp == "" || (x["companion_id"] as? String) == comp) &&
                    (asker == nil || !["user", "contact"].contains(asker!) || (x["asker"] as? String) == asker)
            }.sorted { LocalStore.date($0["created_at"]) > LocalStore.date($1["created_at"]) }
            for x in rows { resume(host, x) }
            return .json(rows.prefix(200).map { publicOut($0, zh: zh) })
        case ("GET", 3) where p[1] == "readings":
            guard let x = reading(s, rid) else { return .error(404, String(localized: "没有这一局")) }
            resume(host, x)
            return .json(publicOut(x, zh: zh))
        case ("POST", 4) where p[1] == "readings" && p[3] == "followup": return followup(host, rid, r.json, zh: zh)
        case ("POST", 4) where p[1] == "readings" && p[3] == "retry":
            guard var x = reading(s, rid) else { return .error(404, String(localized: "没有这一局")) }
            var fus = x["followups"] as? [[String: Any]] ?? []
            let idx = fus.indices.filter { (fus[$0]["status"] as? String) == "failed" }
            guard (x["status"] as? String) == "failed" || !idx.isEmpty else { return .error(409, String(localized: "这一局没有解失败的")) }
            for i in idx { fus[i]["status"] = "pending"; fus[i]["tries"] = 0 }
            x["followups"] = fus
            if (x["status"] as? String) == "failed" { x["status"] = "pending"; x["tries"] = 0 }
            save(s, x)
            if (x["status"] as? String) == "pending" { kick(host, rid ?? 0, followup: nil) }
            for i in idx { kick(host, rid ?? 0, followup: i) }
            return .json(publicOut(x, zh: zh))
        case ("DELETE", 3) where p[1] == "readings":
            guard reading(s, rid) != nil else { return .error(404, String(localized: "没有这一局")) }
            s.saveCollection("tarot", s.collection("tarot").filter { ($0["id"] as? Int) != rid })
            return .empty
        default: return nil
        }
    }

    /// 界面语言跟第一个联系人的设置走（服务器也这样）
    static func accountZh(_ host: LocalHost) -> Bool {
        ((host.store.companions.first?["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
    }

    static func reading(_ s: LocalStore, _ id: Int?) -> [String: Any]? {
        guard let id else { return nil }
        return s.collection("tarot").first { ($0["id"] as? Int) == id }
    }

    static func save(_ s: LocalStore, _ x: [String: Any]) {
        var all = s.collection("tarot")
        if let i = all.firstIndex(where: { ($0["id"] as? Int) == (x["id"] as? Int) }) { all[i] = x } else { all.append(x) }
        s.saveCollection("tarot", all)
    }

    static func face(_ c: [String: Any], zh: Bool) -> [String: Any] {
        let key = c["card"] as? String ?? "", rev = c["reversed"] as? Bool ?? false
        return ["position": c["position"] ?? "", "card": key, "reversed": rev, "name": name(key, zh: zh),
                "keywords": side(key, reversed: rev, zh: zh).keywords]
    }

    static func publicOut(_ x: [String: Any], zh: Bool) -> [String: Any] {
        let fus = (x["followups"] as? [[String: Any]] ?? []).map { f -> [String: Any] in
            ["question": f["question"] ?? "", "card": face(f["card"] as? [String: Any] ?? [:], zh: zh), "mode": f["mode"] ?? "hand",
             "interpretation": f["interpretation"] ?? "", "status": f["status"] ?? "pending", "ts": f["ts"] ?? ""]
        }
        return ["id": x["id"] ?? 0, "reader": x["companion_id"] ?? NSNull(), "asker": x["asker"] ?? "user",
                "drawn_by": x["drawn_by"] ?? "user", "question": x["question"] ?? "", "spread": x["spread"] ?? "",
                "spread_name": spreadName(x["spread"] as? String ?? "", zh: zh), "mode": x["mode"] ?? "hand",
                "cards": (x["cards"] as? [[String: Any]] ?? []).map { face($0, zh: zh) },
                "interpretation": x["interpretation"] ?? "", "status": x["status"] ?? "pending", "followups": fus,
                "created_at": x["created_at"] ?? ""]
    }

    /// 取出那副牌（用一次就作废；过期的找不到）
    private static func takeDeck(_ s: LocalStore, _ id: Int) -> (seed: String, deck: [[String: Any]])? {
        let all = s.collection("tarot-decks")
        guard let d = all.first(where: { ($0["id"] as? Int) == id }) else { return nil }
        s.saveCollection("tarot-decks", all.filter { ($0["id"] as? Int) != id })
        guard Date().timeIntervalSince(LocalStore.date(d["created_at"])) < deckTTL else { return nil }
        return (d["seed"] as? String ?? "", d["deck"] as? [[String: Any]] ?? [])
    }

    private static func picks(_ raw: Any?, count: Int) -> [Int]? {
        let ps = (raw as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
        guard ps.count == count, Set(ps).count == count, ps.allSatisfy({ (0..<78).contains($0) }) else { return nil }
        return ps
    }

    static func create(_ host: LocalHost, _ b: [String: Any]) -> LocalResponse {
        let s = host.store
        let key = b["spread"] as? String ?? ""
        guard key != "followup", let sp = spread(key) else { return .error(400, String(localized: "没有这个牌阵")) }
        let mode = b["mode"] as? String ?? ""
        guard ["hand", "auto"].contains(mode) else { return .error(400, "mode 只能是 hand / auto") }
        let q = (b["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .error(400, String(localized: "问题不能是空的")) }
        let count = (sp["layout"] as? [Any])?.count ?? 1
        guard let ps = picks(b["picks"], count: count) else { return .error(400, String(localized: "要从这副牌里挑 \(count) 张不重复的")) }
        let comps = s.companions.compactMap { $0["id"] as? String }
        let from = (b["from"] as? String)?.lowercased()
        let reader = (b["reader"] as? String)?.lowercased()
        if let reader, !comps.contains(reader) { return .error(404, String(localized: "没有这个联系人")) }
        let routeFrom = from.flatMap { comps.contains($0) ? $0 : nil } ?? comps.first
        let zh = ((s.companion(reader ?? routeFrom ?? "")?["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        guard let (seed, deck) = takeDeck(s, b["deck_id"] as? Int ?? 0) else {
            return .error(400, String(localized: "这副牌找不到了或已经过期，重新洗一次"))
        }
        let cards: [[String: Any]] = zip(positions(key, zh: zh), ps).map { pos, i in
            ["position": pos, "card": deck[i]["card"] ?? "", "reversed": deck[i]["reversed"] ?? false]
        }
        let x: [String: Any] = ["id": s.nextID("tarot"), "companion_id": reader ?? NSNull(), "route_from": routeFrom ?? NSNull(),
                                "asker": "user", "drawn_by": "user", "question": String(q.prefix(maxQuestion)), "spread": key,
                                "cards": cards, "seed": seed, "mode": mode, "interpretation": "", "status": "pending", "tries": 0,
                                "told": false, "followups": [[String: Any]](), "created_at": LocalStore.iso(Date())]
        save(s, x)
        kick(host, x["id"] as? Int ?? 0, followup: nil)
        return .json(publicOut(x, zh: zh), status: 201)
    }

    static func followup(_ host: LocalHost, _ rid: Int?, _ b: [String: Any], zh: Bool) -> LocalResponse {
        let s = host.store
        guard var x = reading(s, rid) else { return .error(404, String(localized: "没有这一局")) }
        let mode = b["mode"] as? String ?? ""
        guard ["hand", "auto"].contains(mode) else { return .error(400, "mode 只能是 hand / auto") }
        let q = (b["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .error(400, String(localized: "问题不能是空的")) }
        guard let p = picks([b["pick"] as Any], count: 1)?.first else { return .error(400, String(localized: "要从这副牌里挑 1 张不重复的")) }
        guard (x["status"] as? String) == "done", !(x["interpretation"] as? String ?? "").isEmpty else {
            return .error(400, String(localized: "这一局还没解完，等解完再追问"))
        }
        guard let (seed, deck) = takeDeck(s, b["deck_id"] as? Int ?? 0) else {
            return .error(400, String(localized: "这副牌找不到了或已经过期，重新洗一次"))
        }
        var fus = x["followups"] as? [[String: Any]] ?? []
        fus.append(["question": String(q.prefix(maxQuestion)),
                    "card": ["position": positions("followup", zh: zh).first ?? "追问", "card": deck[p]["card"] ?? "", "reversed": deck[p]["reversed"] ?? false],
                    "seed": seed, "mode": mode, "interpretation": "", "status": "pending", "tries": 0, "ts": LocalStore.iso(Date())])
        x["followups"] = fus
        save(s, x)
        kick(host, rid ?? 0, followup: fus.count - 1)
        return .json(publicOut(x, zh: zh), status: 201)
    }

    // MARK: - 解牌（后台跑，用你的 key；没有服务器巡逻，失败了在这儿自己重试，三次不成标 failed）

    nonisolated(unsafe) private static var running: Set<String> = []
    private static let lock = NSLock()

    /// 打开牌局时：上次 App 关掉没跑完的（还 pending / asked），接着跑
    static func resume(_ host: LocalHost, _ x: [String: Any]) {
        let id = x["id"] as? Int ?? 0
        if ["pending", "asked"].contains(x["status"] as? String ?? "") { kick(host, id, followup: nil) }
        for (i, f) in (x["followups"] as? [[String: Any]] ?? []).enumerated() where ["pending", "asked"].contains(f["status"] as? String ?? "") {
            kick(host, id, followup: i)
        }
    }

    static func kick(_ host: LocalHost, _ rid: Int, followup: Int?) {
        let tag = "\(rid)-\(followup ?? -1)"
        let go = lock.withLock { () -> Bool in
            if running.contains(tag) { return false }
            running.insert(tag)
            return true
        }
        guard go else { return }
        Task.detached {
            defer { _ = lock.withLock { running.remove(tag) } }
            for attempt in 1...maxTries {
                setStatus(host.store, rid, followup, "asked", tries: attempt)
                switch await readOnce(host, rid, followup: followup) {
                case .done: return
                case .skipped:
                    setStatus(host.store, rid, followup, "failed", tries: attempt)
                    return
                case .error:
                    if attempt == maxTries { setStatus(host.store, rid, followup, "failed", tries: attempt); return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private static func setStatus(_ s: LocalStore, _ rid: Int, _ followup: Int?, _ status: String, tries: Int) {
        guard var x = reading(s, rid) else { return }
        if let followup {
            var fus = x["followups"] as? [[String: Any]] ?? []
            guard fus.indices.contains(followup), (fus[followup]["status"] as? String) != "done" else { return }
            fus[followup]["status"] = status; fus[followup]["tries"] = tries
            x["followups"] = fus
        } else {
            guard (x["status"] as? String) != "done" else { return }
            x["status"] = status; x["tries"] = tries
        }
        save(s, x)
    }

    /// 写解读。TA 抽、联系人解的主解读写好后 told = false（它下一轮递〔塔罗〕）；解牌人的、它自己抽的不递。
    static func write(_ s: LocalStore, _ rid: Int, _ text: String, followup: Int?) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxText))
        guard !text.isEmpty, var x = reading(s, rid) else { return }
        if let followup {
            var fus = x["followups"] as? [[String: Any]] ?? []
            guard fus.indices.contains(followup) else { return }
            fus[followup]["interpretation"] = text; fus[followup]["status"] = "done"
            x["followups"] = fus
        } else {
            x["interpretation"] = text; x["status"] = "done"
            x["told"] = x["companion_id"] is NSNull || x["companion_id"] == nil || (x["drawn_by"] as? String) == "contact"
        }
        save(s, x)
    }

    enum Outcome { case done, error, skipped }

    static let neutral = ["zh": "你是 Mele 里的解牌人。你不认识这个人，也不扮演任何角色；只就 TA 的问题和抽到的牌说话。",
                          "en": "You are the Reader in Mele. You don't know this person and play no character; speak only to their question and the cards."]

    static func cardLines(_ cards: [[String: Any]], zh: Bool) -> String {
        cards.map { "· \($0["position"] ?? "")｜\(entryLine($0["card"] as? String ?? "", reversed: $0["reversed"] as? Bool ?? false, zh: zh))" }
            .joined(separator: "\n")
    }

    static func askText(_ x: [String: Any], zh: Bool, followup: Int?) -> String {
        let cards = x["cards"] as? [[String: Any]] ?? []
        let q = x["question"] as? String ?? ""
        let sp = spreadName(x["spread"] as? String ?? "", zh: zh)
        var lines = [zh ? "〔塔罗〕TA 问了牌，请你来解。" : "〔Tarot〕They've asked the cards and want you to read.", "",
                     manuals[lang(zh)] ?? "", "",
                     zh ? "TA 问：「\(q)」\n牌阵：\(sp)" : "They asked: \"\(q)\"\nSpread: \(sp)", cardLines(cards, zh: zh)]
        if let followup {
            let fus = x["followups"] as? [[String: Any]] ?? []
            lines += ["", zh ? "你之前的解读：" : "Your earlier reading:", x["interpretation"] as? String ?? ""]
            for f in fus.prefix(followup) {
                lines += ["", zh ? "之前追问：「\(f["question"] ?? "")」" : "Earlier follow-up: \"\(f["question"] ?? "")\"",
                          cardLines([f["card"] as? [String: Any] ?? [:]], zh: zh), f["interpretation"] as? String ?? ""]
            }
            if fus.indices.contains(followup) {
                let f = fus[followup]
                lines += ["", zh ? "现在 TA 接着问：「\(f["question"] ?? "")」，又抽了一张——只解这一张，接上前面的。"
                                 : "Now they ask: \"\(f["question"] ?? "")\" and drew one more card — read just this one, carrying on from before.",
                          cardLines([f["card"] as? [String: Any] ?? [:]], zh: zh)]
            }
        }
        lines += ["", zh ? "照上面的手册解。直接写出给 TA 看的那段解读，不要别的话。" : "Read by the manual above. Write only the reading itself, nothing else."]
        return lines.joined(separator: "\n")
    }

    static func readOnce(_ host: LocalHost, _ rid: Int, followup: Int?) async -> Outcome {
        let s = host.store
        guard let x = reading(s, rid) else { return .skipped }
        let reader = x["companion_id"] as? String
        let comps = s.companions
        // 用谁的钥匙：解的那个联系人；解牌人用问牌时所在的那个（删了就换第一个）
        let keyOwner = reader.flatMap { s.companion($0) }
            ?? (x["route_from"] as? String).flatMap { s.companion($0) } ?? comps.first
        guard let owner = keyOwner, let (provider, key) = host.route(for: owner), !LiteConsent.book.needsAsk(provider) else { return .skipped }
        let settings = owner["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        var ask = askText(x, zh: zh, followup: followup)
        var system = neutral[lang(zh)] ?? ""
        if let reader, let comp = s.companion(reader) {
            let contact = LocalBrain.contact(comp, provider: provider)
            let ident = contact.mainIdentity
            system = zh ? "你是\(contact.name)。\n\n\(contact.persona)" : "You are \(contact.name).\n\n\(contact.persona)"
            if !ident.relationship.isEmpty { system += "\n\n" + ident.relationship }
            if !ident.userName.isEmpty { system += zh ? "\n\n你叫 TA「\(ident.userName)」。" : "\n\nYou call them \"\(ident.userName)\"." }
            let recent = recentLines(s, companion: reader, zh: zh, userName: ident.userName)
            if !recent.isEmpty { ask = recent + "\n\n" + ask }
        }
        var req = ChatRequest(system: system, turns: [ChatTurn(role: .user, text: ask)], maxTokens: 4000)
        req.tools = []
        var text = ""
        do {
            for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
        } catch { return .error }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error }
        write(s, rid, text, followup: followup)
        return .done
    }

    /// 最近聊的几句（让它解的时候知道你们刚聊到哪）
    static func recentLines(_ s: LocalStore, companion: String, zh: Bool, userName: String) -> String {
        guard let conv = s.conversations.filter({ ($0["companion_id"] as? String) == companion && LocalHost.isMainWindow($0) })
            .max(by: { LocalStore.date($0["last_at"]) < LocalStore.date($1["last_at"]) })?["id"] as? String else { return "" }
        let msgs = s.messages(conv).suffix(8)
        guard !msgs.isEmpty else { return "" }
        let ta = userName.isEmpty ? "TA" : userName
        let lines = msgs.map { m -> String in
            let t = (m["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            let who = (m["role"] as? String) == "assistant" ? (zh ? "你" : "You") : ta
            return "\(who)：\(t.count > 120 ? String(t.prefix(120)) + "…" : t)"
        }
        return (zh ? "你们最近聊的几句：\n" : "Your last few messages:\n") + lines.joined(separator: "\n")
    }

    // MARK: - 聊天那边：〔塔罗〕和工具

    /// TA 抽、它解好的那一局，它下一次开口时递一次（解牌人的局不会到这儿）。一次只递一局。
    static func pendingNote(_ s: LocalStore, companion: String, zh: Bool) -> String {
        guard var x = s.collection("tarot").filter({ ($0["companion_id"] as? String) == companion && !($0["told"] as? Bool ?? true)
            && ($0["status"] as? String) == "done" })
            .max(by: { LocalStore.date($0["created_at"]) < LocalStore.date($1["created_at"]) }) else { return "" }
        x["told"] = true
        save(s, x)
        let gist = (x["interpretation"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let short = gist.count > 120 ? String(gist.prefix(120)) + "…" : gist
        let cards = (x["cards"] as? [[String: Any]] ?? []).map {
            "\($0["position"] ?? "")·\(name($0["card"] as? String ?? "", zh: zh))\(($0["reversed"] as? Bool ?? false) ? (zh ? "（逆）" : " (rev.)") : "")"
        }.joined(separator: zh ? "、" : ", ")
        let sp = spreadName(x["spread"] as? String ?? "", zh: zh)
        if zh { return "〔塔罗〕TA 在塔罗房间里问了「\(x["question"] ?? "")」（\(sp)：\(cards)），你给解了：\(short)　想聊就提。" }
        return "〔Tarot〕In the Tarot room they asked \"\(x["question"] ?? "")\" (\(sp): \(cards)), and you read it: \(short)  Bring it up if you like."
    }

    static func toolSpec(zh: Bool) -> ToolSpec {
        ToolSpec(name: "tarot",
                 description: zh ? "用途：塔罗。draw=抽牌：心里有事想问自己，或者 TA 在聊天里说「帮我抽一张」（这时 for_ta=true），写下问题、挑牌阵；抽完拿到每个牌位的牌和牌义。read=给你自己抽的那一局写解读（TA 在塔罗房间里看得到）；替 TA 抽的，在聊天里直接解给 TA 听，也 read 留一份。list=翻最近的牌局。"
                                 : "Tarot. draw = draw cards: for something on your own mind, or when they ask you in chat to draw for them (for_ta=true); give the question and a spread, and you get each position's card and meaning. read = write your reading for a spread you drew (they can see it in the Tarot room); for one you drew for them, read it to them in chat and also save it with read. list = recent readings.",
                 parametersJSON: #"{"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["draw","read","list"]},"question":{"type":"string","description":"draw：问的是什么"},"spread":{"type":"string","enum":["single","three","relationship","choice","diamond","moon","week","horseshoe","celtic"],"description":"draw：牌阵，默认 single"},"for_ta":{"type":"boolean","description":"draw：替 TA 抽（TA 在聊天里叫你抽的）"},"id":{"type":"integer","description":"read：牌局编号"},"text":{"type":"string","description":"read：你的解读"}}}"#)
    }

    static func runTool(_ a: [String: Any], host: LocalHost, companion: String, zh: Bool) -> LocalTools.Outcome {
        let s = host.store
        switch a["action"] as? String ?? "" {
        case "draw":
            let key = (a["spread"] as? String).flatMap { spread($0) != nil && $0 != "followup" ? $0 : nil } ?? "single"
            let q = (a["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return .init(result: zh ? "问题不能是空的" : "The question can't be empty", card: nil) }
            let seed = makeSeed()
            let deck = shuffle(seed: seed)
            let cards: [[String: Any]] = positions(key, zh: zh).enumerated().map { i, pos in
                ["position": pos, "card": deck[i]["card"] ?? "", "reversed": deck[i]["reversed"] ?? false]
            }
            let x: [String: Any] = ["id": s.nextID("tarot"), "companion_id": companion, "route_from": companion,
                                    "asker": (a["for_ta"] as? Bool ?? false) ? "user" : "contact", "drawn_by": "contact",
                                    "question": String(q.prefix(maxQuestion)), "spread": key, "cards": cards, "seed": seed, "mode": "tool",
                                    "interpretation": "", "status": "done", "tries": 0, "told": true,
                                    "followups": [[String: Any]](), "created_at": LocalStore.iso(Date())]
            save(s, x)
            let snip = q.count > 40 ? String(q.prefix(40)) + "…" : q
            return .init(result: "#\(x["id"] ?? 0) \(spreadName(key, zh: zh))「\(q)」\n\(cardLines(cards, zh: zh))\n"
                            + (zh ? "想好了用 tarot read 写下你的解读。" : "When you've thought it over, write your reading with tarot read."),
                         card: ["kind": "tarot", "text": zh ? "抽了牌：\(snip)" : "drew cards: \(snip)"])
        case "read":
            guard let x = reading(s, a["id"] as? Int), (x["companion_id"] as? String) == companion, (x["drawn_by"] as? String) == "contact" else {
                return .init(result: zh ? "只能给你自己抽的那几局写解读" : "You can only write readings for spreads you drew", card: nil)
            }
            write(s, x["id"] as? Int ?? 0, a["text"] as? String ?? "", followup: nil)
            return .init(result: zh ? "写好了。" : "Written.", card: nil)
        case "list":
            let rows = s.collection("tarot").filter { ($0["companion_id"] as? String) == companion }
                .sorted { LocalStore.date($0["created_at"]) > LocalStore.date($1["created_at"]) }.prefix(5)
            guard !rows.isEmpty else { return .init(result: zh ? "还没有抽过牌。" : "No readings yet.", card: nil) }
            let f = DateFormatter()
            f.dateFormat = "MM-dd"
            return .init(result: rows.map { x in
                let who = (x["asker"] as? String) == "user" ? (zh ? "TA 问" : "they asked") : (zh ? "你问" : "you asked")
                let interp = x["interpretation"] as? String ?? ""
                let cards = (x["cards"] as? [[String: Any]] ?? []).map { name($0["card"] as? String ?? "", zh: zh) }.joined(separator: zh ? "、" : ", ")
                return "#\(x["id"] ?? 0) \(f.string(from: LocalStore.date(x["created_at"]))) \(who)「\(x["question"] ?? "")」（\(cards)）\(interp.count > 60 ? String(interp.prefix(60)) + "…" : interp)"
            }.joined(separator: "\n"), card: nil)
        default:
            return .init(result: "action 只能是 draw / read / list", card: nil)
        }
    }
}
#endif
