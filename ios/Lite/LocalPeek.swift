#if LITE
import Foundation

/// 它翻你的手机（10-04 Tilia：什么都能给看，但它得先在聊天里申请）。
/// 它写 ⟪想查手机：想看什么⟫ → 聊天里一张申请卡 → 你点「给看」（勾哪几间）或「不给」→ 它带着翻到的东西 / 被拒的旁白再说一轮。
/// - 跟它自己的聊天不给（它本来就知道）；小号窗口的聊天、私密日记不给。
enum LocalPeek {
    /// 能给看的几间（界面那份在 PeekGrantSheet，顺序一致）
    static let rooms = ["chats", "diary", "wallet", "food", "album", "todos", "moments", "favorites", "books", "music", "lore", "stickers"]

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        guard r.method == "POST", p.count == 3, p[0] == "conversations", p[2] == "peek" else { return nil }
        let conv = p[1]
        guard host.store.conversation(conv) != nil, let comp = host.companion(ofConversation: conv) else {
            return .error(404, String(localized: "没有这个窗口"))
        }
        // 最近那张还没答的申请卡
        var msgs = host.store.messages(conv)
        guard let mi = msgs.indices.reversed().first(where: { i in
            (msgs[i]["cards"] as? [[String: Any]] ?? []).contains { ($0["kind"] as? String) == "peek" && (($0["data"] as? [String: Any])?["state"] as? String) == "ask" }
        }) else { return .error(409, String(localized: "这张已经答过了")) }
        let allow = r.json["allow"] as? Bool ?? false
        let picked = Set((r.json["rooms"] as? [String] ?? rooms).filter(rooms.contains))
        var cards = msgs[mi]["cards"] as? [[String: Any]] ?? []
        if let ci = cards.lastIndex(where: { ($0["kind"] as? String) == "peek" }) {
            cards[ci]["data"] = ["state": allow ? "ok" : "no", "rooms": allow ? rooms.filter(picked.contains) : []]
        }
        msgs[mi]["cards"] = cards
        host.store.saveMessages(conv, msgs)

        let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        if allow {
            let snap = snapshot(host.store, viewer: comp["id"] as? String ?? "", rooms: picked, zh: zh)
            host.brain.poke(conv, nudge: zh ? "（TA 把手机递给你了）" : "(They handed you their phone.)", peek: snap)
        } else {
            host.brain.poke(conv, nudge: zh ? "（TA 没把手机给你）" : "(They didn't hand you their phone.)")
        }
        return .json(["ok": true, "state": allow ? "ok" : "no"])
    }

    /// 给看的那几间拼成一段字
    static func snapshot(_ s: LocalStore, viewer: String, rooms picked: Set<String>, zh: Bool, cap: Int = 14000) -> String {
        var parts: [String] = []
        func add(_ title: String, _ lines: [String]) {
            let ls = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !ls.isEmpty { parts.append("## \(title)\n" + ls.joined(separator: "\n")) }
        }
        func cut(_ any: Any?, _ n: Int) -> String {
            let t = (any as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }
        let names = Dictionary(s.companions.compactMap { c -> (String, String)? in
            guard let id = c["id"] as? String else { return nil }
            return (id, (c["persona"] as? [String: Any])?["name"] as? String ?? "TA")
        }, uniquingKeysWith: { a, _ in a })

        if picked.contains("chats") {
            for (cid, name) in names where cid != viewer {
                let convs = s.conversations.filter { ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) }
                    .sorted { LocalStore.date($0["last_at"]) > LocalStore.date($1["last_at"]) }
                guard let conv = convs.first?["id"] as? String else { continue }
                let msgs = s.messages(conv).suffix(20)
                add(zh ? "跟 \(name) 的聊天（最近 \(msgs.count) 句）" : "Chat with \(name) (last \(msgs.count))",
                    msgs.map { "\(($0["role"] as? String) == "assistant" ? name : "TA")：\(cut($0["text"], 200))" })
            }
        }
        if picked.contains("diary") {
            let es = s.collection("diary").filter { ($0["author"] as? String) == "user" && ($0["private"] as? Bool) != true }
                .sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }.prefix(8)
            add(zh ? "日记" : "Diary", es.map { "\($0["day"] as? String ?? "")：\(cut($0["body"], 300))" })
        }
        if picked.contains("wallet") {
            let es = s.collection("wallet").sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }.prefix(30)
            add(zh ? "钱包（最近的账）" : "Wallet (recent)", es.map { e in
                let out = (e["kind"] as? String) != "in"
                let amt = (e["amount"] as? Double).map { String(format: "%.2f", $0) } ?? "\(e["amount"] ?? "")"
                return "\(e["day"] as? String ?? "") \(out ? (zh ? "花" : "spent") : (zh ? "收" : "got")) \(amt) · \(e["category"] as? String ?? "") \(cut(e["note"], 40))"
            })
        }
        if picked.contains("food") {
            let es = s.collection("food").sorted { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }.prefix(25)
            add(zh ? "饮食" : "Food", es.map { e in
                let k = (e["kcal"] as? Double).map { " (\(Int($0)) kcal)" } ?? ""
                return "\(e["date"] as? String ?? "") \(e["meal"] as? String ?? "")：\(cut(e["text"], 60))\(k)"
            })
        }
        if picked.contains("album") {
            let es = s.collection("album").filter { ($0["secret"] as? Bool) != true }
                .sorted { LocalStore.date($0["taken_at"]) > LocalStore.date($1["taken_at"]) }.prefix(20)
            add(zh ? "相册（照片的说明）" : "Photos (captions)", es.map { e in
                let say = [e["caption"], e["note"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " · ")
                return say.isEmpty ? "" : "· " + cut(say, 120)
            })
        }
        if picked.contains("todos") {
            let es = s.collection("todos").filter { !LocalRooms2.isDone($0) }.prefix(20)
            add(zh ? "待办" : "To-dos", es.map { "· " + cut($0["what"], 80) })
        }
        if picked.contains("moments") {
            let es = s.collection("moments").filter { ($0["author"] as? String) == "user" }
                .sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }.prefix(10)
            add(zh ? "TA 发的朋友圈" : "Their posts", es.map { "· " + cut($0["content"], 160) })
        }
        if picked.contains("favorites") {
            let es = s.collection("favorites").sorted { LocalStore.date($0["saved_at"]) > LocalStore.date($1["saved_at"]) }.prefix(15)
            add(zh ? "收藏" : "Favorites", es.map { "· " + cut($0["text"], 160) })
        }
        if picked.contains("books") {
            add(zh ? "书架" : "Bookshelf", s.collection("books").map { "·《\($0["title"] as? String ?? "")》" })
        }
        if picked.contains("music") {
            let es = s.collection("music-shelf").sorted { LocalStore.date($0["created_at"]) > LocalStore.date($1["created_at"]) }.prefix(20)
            add(zh ? "存下的歌" : "Saved songs", es.map { "· \($0["name"] as? String ?? "") — \($0["artist"] as? String ?? "")" })
        }
        if picked.contains("lore") {
            let ts = s.collection("lore").compactMap { $0["title"] as? String }
            add(zh ? "世界书" : "Lorebook", ts.isEmpty ? [] : [ts.joined(separator: "、")])
        }
        if picked.contains("stickers") {
            let cs = s.collection("stickers").compactMap { $0["caption"] as? String }.filter { !$0.isEmpty }
            add(zh ? "表情包" : "Stickers", cs.isEmpty ? [] : [cs.prefix(60).joined(separator: "、")])
        }
        if parts.isEmpty { return zh ? "（翻了一圈，没找到什么）" : "(You looked around and found nothing much.)" }
        let all = parts.joined(separator: "\n\n")
        return all.count > cap ? String(all.prefix(cap)) + "…" : all
    }
}
#endif
