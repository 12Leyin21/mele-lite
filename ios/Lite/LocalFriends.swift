#if LITE
import Foundation
import UserNotifications

/// 小号 + 加好友（10-04 Tilia）：每个联系人有个「微信号」（TA 的设定里能改）；你在消息列表右上角建小号，
/// 用小号输微信号申请加好友 → 它过一会儿（20 秒～2 分半）通过 → 开一个小号窗口，它先开口。
/// App 关着的时候到点了，下次打开再通过（到点那刻发一条本地提醒）。
/// 存：rooms/alts.json（你的小号）、rooms/friend_requests.json（申请，state = pending / accepted）
enum LocalFriends {
    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts, s = host.store
        switch (r.method, p.count) {
        case ("GET", 1) where p[0] == "alts":
            migrate(s)
            return .json(s.collection("alts"))
        case ("POST", 1) where p[0] == "alts":
            let name = (r.json["user_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .error(400, String(localized: "给小号起个名字")) }
            let a: [String: Any] = ["id": UUID().uuidString.lowercased(), "user_name": String(name.prefix(20)),
                                    "about_me": String((r.json["about_me"] as? String ?? "").prefix(400)),
                                    "created_at": LocalStore.iso(Date())]
            s.saveCollection("alts", s.collection("alts") + [a])
            return .json(a, status: 201)
        case ("DELETE", 2) where p[0] == "alts":        // 删小号：它加的好友、聊天一起删
            for c in s.conversations where ((c["alt"] as? [String: Any])?["id"] as? String) == p[1] {
                _ = host.deleteConversation(c["id"] as? String ?? "")
            }
            s.saveCollection("alts", s.collection("alts").filter { ($0["id"] as? String) != p[1] })
            s.saveCollection("friend_requests", s.collection("friend_requests").filter { ($0["alt_id"] as? String) != p[1] })
            return .empty
        case ("GET", 2) where p == ["friends", "lookup"]:
            guard let c = find(s, r.query["wechat_id"] ?? "") else { return .error(404, String(localized: "没有找到这个微信号")) }
            return .json(["companion_id": c["id"] ?? "", "name": (c["persona"] as? [String: Any])?["name"] ?? "TA",
                          "wechat_id": wechatID(s, c), "avatar_ver": c["avatar_ver"] ?? 0])
        case ("GET", 2) where p == ["friends", "requests"]:
            tick(host)
            return .json(s.collection("friend_requests").map { out(s, $0) })
        case ("POST", 2) where p == ["friends", "requests"]:
            return request(host, r.json)
        default:
            return nil
        }
    }

    /// 10-04 早先的小号窗口：窗口里的 alt.id 对不上小号的 id（加好友那条记着），对齐；
    /// 更早从聊天 ⋯ 开的小号窗口没有对应的小号，补一个同名的
    static func migrate(_ s: LocalStore) {
        var convs = s.conversations, alts = s.collection("alts")
        let byConv = Dictionary(s.collection("friend_requests").compactMap { q -> (String, String)? in
            guard let c = q["conversation"] as? String, let a = q["alt_id"] as? String else { return nil }
            return (c, a)
        }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for i in convs.indices {
            guard var alt = convs[i]["alt"] as? [String: Any], let cid = convs[i]["id"] as? String else { continue }
            let aid = alt["id"] as? String ?? ""
            if let want = byConv[cid], want != aid {
                alt["id"] = want; convs[i]["alt"] = alt; changed = true
            } else if byConv[cid] == nil, !alts.contains(where: { ($0["id"] as? String) == aid }) {
                alts.append(["id": aid, "user_name": alt["user_name"] ?? "", "about_me": alt["about_me"] ?? "",
                             "created_at": convs[i]["created_at"] ?? LocalStore.iso(Date())])
                changed = true
            }
        }
        guard changed else { return }
        s.conversations = convs
        s.saveCollection("alts", alts)
    }

    // MARK: 微信号

    /// 没设过就按名字起一个（中文转拼音，再加 4 位数），存回去
    static func wechatID(_ s: LocalStore, _ c: [String: Any]) -> String {
        if let w = (c["persona"] as? [String: Any])?["wechat_id"] as? String, !w.isEmpty { return w }
        let name = (c["persona"] as? [String: Any])?["name"] as? String ?? ""
        let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name).applyingTransform(.stripDiacritics, reverse: false) ?? name
        var base = latin.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if base.isEmpty { base = "mele" }
        var id = ""
        repeat { id = String(base.prefix(12)) + "_" + String(format: "%04d", Int.random(in: 0...9999)) }
        while s.companions.contains { ($0["id"] as? String) != (c["id"] as? String) && sameID(($0["persona"] as? [String: Any])?["wechat_id"], id) }
        var cc = c
        var persona = cc["persona"] as? [String: Any] ?? [:]
        persona["wechat_id"] = id
        cc["persona"] = persona
        s.saveCompanion(cc)
        return id
    }

    /// 改微信号前查一下：6～20 位字母 / 数字 / _ -，字母开头，不跟别人撞
    static func validate(_ s: LocalStore, companion: String, _ raw: String) -> (String?, String) {
        let w = raw.trimmingCharacters(in: .whitespaces)
        guard (6...20).contains(w.count), w.first?.isLetter == true, w.first?.isASCII == true,
              w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            return (nil, String(localized: "微信号要 6～20 位，字母开头，只能有字母、数字、_ 和 -"))
        }
        if s.companions.contains(where: { ($0["id"] as? String) != companion && sameID(($0["persona"] as? [String: Any])?["wechat_id"], w) }) {
            return (nil, String(localized: "这个微信号已经被别的联系人用了"))
        }
        return (w, "")
    }

    private static func sameID(_ a: Any?, _ b: String) -> Bool { (a as? String)?.lowercased() == b.lowercased() }

    static func find(_ s: LocalStore, _ raw: String) -> [String: Any]? {
        let w = raw.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        for c in s.companions where sameID(wechatID(s, c), w) { return s.companion(c["id"] as? String ?? "") }
        return nil
    }

    // MARK: 申请

    private static func request(_ host: LocalHost, _ b: [String: Any]) -> LocalResponse {
        let s = host.store
        guard let alt = s.collection("alts").first(where: { ($0["id"] as? String) == (b["alt_id"] as? String) }) else {
            return .error(404, String(localized: "没有这个小号"))
        }
        guard let c = find(s, b["wechat_id"] as? String ?? ""), let cid = c["id"] as? String else {
            return .error(404, String(localized: "没有找到这个微信号"))
        }
        let altID = alt["id"] as? String ?? ""
        if s.collection("friend_requests").contains(where: { ($0["alt_id"] as? String) == altID && ($0["companion_id"] as? String) == cid }) {
            return .error(409, String(localized: "这个小号已经加过 TA 了"))
        }
        let wait = Double.random(in: 20...150)
        let at = Date().addingTimeInterval(wait)
        let req: [String: Any] = ["id": s.nextID("friend_request"), "alt_id": altID, "companion_id": cid,
                                  "greeting": String((b["greeting"] as? String ?? "").prefix(60)),
                                  "created_at": LocalStore.iso(Date()), "accept_at": LocalStore.iso(at), "state": "pending"]
        s.saveCollection("friend_requests", s.collection("friend_requests") + [req])
        notify(at: at, name: (c["persona"] as? [String: Any])?["name"] as? String ?? "TA", alt: alt["user_name"] as? String ?? "", id: req["id"] as? Int ?? 0)
        Task {                                  // App 开着就到点通过；关了下次 tick 再补
            try? await Task.sleep(for: .seconds(wait + 0.5))
            tick(host)
        }
        return .json(out(s, req), status: 201)
    }

    private static func out(_ s: LocalStore, _ q: [String: Any]) -> [String: Any] {
        var o = q
        let alt = s.collection("alts").first { ($0["id"] as? String) == (q["alt_id"] as? String) }
        let c = s.companion(q["companion_id"] as? String ?? "")
        o["alt_name"] = alt?["user_name"] ?? ""
        o["name"] = (c?["persona"] as? [String: Any])?["name"] ?? "TA"
        return o
    }

    private static let tickLock = NSLock()

    /// 到点的申请：通过 → 开小号窗口 → 它先开口
    static func tick(_ host: LocalHost) {
        let s = host.store
        migrate(s)
        let due: [[String: Any]] = tickLock.withLock {
            var all = s.collection("friend_requests")
            var due: [[String: Any]] = []
            for i in all.indices where (all[i]["state"] as? String) == "pending" && LocalStore.date(all[i]["accept_at"]) <= Date() {
                all[i]["state"] = "accepted"
                due.append(all[i])
            }
            if !due.isEmpty { s.saveCollection("friend_requests", all) }
            return due
        }
        for q in due {
            guard let cid = q["companion_id"] as? String, let comp = s.companion(cid),
                  let alt = s.collection("alts").first(where: { ($0["id"] as? String) == (q["alt_id"] as? String) }) else { continue }
            let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
            let conv = host.newConversation(cid, incognito: false, alt: [
                "id": alt["id"] ?? "", "user_name": alt["user_name"] ?? "", "about_me": alt["about_me"] ?? "",
                "relationship": zh ? "陌生人（刚通过微信号加上的好友）" : "strangers (just added each other by ID)"])
            guard let convID = conv["id"] as? String else { continue }
            var all = s.collection("friend_requests")
            if let i = all.firstIndex(where: { ($0["id"] as? Int) == (q["id"] as? Int) }) { all[i]["conversation"] = convID }
            s.saveCollection("friend_requests", all)
            let greet = (q["greeting"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let nudge = zh
                ? "（有个陌生人搜你的微信号加了你\(greet.isEmpty ? "" : "，验证消息写着「\(greet)」")。你刚通过了好友申请。你先开口，跟平时一样说话。）"
                : "(A stranger added you by your ID\(greet.isEmpty ? "" : ", with the note \"\(greet)\""). You just accepted. Say something first, the way you normally would.)"
            host.brain.poke(convID, nudge: nudge)
            DispatchQueue.main.async { NotificationCenter.default.post(name: .liteFriendAccepted, object: nil) }
        }
    }

    private static func notify(at: Date, name: String, alt: String, id: Int) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = name
            n.body = String(localized: "通过了「\(alt)」的好友申请")
            n.sound = .default
            c.add(UNNotificationRequest(identifier: "friend-\(id)", content: n,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)))
        }
    }
}
#endif
