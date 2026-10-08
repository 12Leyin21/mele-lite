#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 第三批：相册、朋友圈（照 routes_album / routes_moments）。它「看照片」「来评论」都用你自己的 key，App 开着时做。
enum LocalRooms3 {
    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        let s = host.store
        switch (r.method, p.first ?? "", p.count) {
        // 相册
        case ("GET", "album", 1): return .json(albumList(s, book: r.query["book"] ?? "all", companion: r.query["companion_id"]))
        case ("GET", "album", 3) where p[2] == "image":
            guard let ph = s.collection("album").first(where: { ($0["id"] as? Int) == Int(p[1]) }),
                  let d = try? Data(contentsOf: s.fileURL(ph["file"] as? String ?? "")) else { return .error(404, String(localized: "没有这张")) }
            return .data(d, mime: "image/jpeg")
        case ("POST", "album", 1): return albumAdd(host, r)
        case ("PATCH", "album", 2):
            var all = s.collection("album")
            guard let i = all.firstIndex(where: { ($0["id"] as? Int) == Int(p[1]) }) else { return .error(404, String(localized: "没有这张")) }
            for k in ["starred", "secret"] where r.json.keys.contains(k) { all[i][k] = r.json[k] as? Bool ?? false }
            s.saveCollection("album", all)
            return .json(albumOut(all[i]))
        case ("DELETE", "album", 2): return LocalRooms.removeWhere(s, "album", 404, String(localized: "没有这张")) { ($0["id"] as? Int) == Int(p[1]) }
        // 朋友圈
        case ("GET", "moments", 1): return .json(feed(host, who: r.query["who"], before: r.query["before"].flatMap(Int.init), limit: Int(r.query["limit"] ?? "20") ?? 20))
        case ("GET", "moments", 2) where p[1] == "activity": return .json(activity(host, since: r.query["since"]))
        case ("POST", "moments", 1): return post(host, r)
        case ("DELETE", "moments", 2):
            return LocalRooms.removeWhere(s, "moments", 404, String(localized: "没有这条（只能删自己发的）")) { ($0["id"] as? Int) == Int(p[1]) && ($0["author"] as? String) == "user" }
        case ("POST", "moments", 3) where p[2] == "like": return like(host, Int(p[1]), r.json["liked"] as? Bool ?? true)
        case ("POST", "moments", 3) where p[2] == "comments": return comment(host, Int(p[1]), r.json)
        case ("DELETE", "moments", 3) where p[1] == "comments": return deleteComment(host, Int(p[2]))
        case ("GET", "moments", 4) where p[2] == "images":
            guard let m = s.collection("moments").first(where: { ($0["id"] as? Int) == Int(p[1]) }),
                  let files = m["images"] as? [String], let n = Int(p[3]), files.indices.contains(n),
                  let d = try? Data(contentsOf: s.fileURL(files[n])) else { return .error(404, String(localized: "没有这张")) }
            return .data(d, mime: "image/jpeg")
        case ("GET", "moments", 3) where p[1] == "profile":
            let prof = (s.read("moments-profiles.json") as? [String: [String: Any]])?[p[2]] ?? [:]
            return .json(["who": p[2], "name": names(host)[p[2]] ?? "", "signature": prof["signature"] ?? "",
                          "has_cover": FileManager.default.fileExists(atPath: s.fileURL("cover-\(p[2])").path)])
        case ("PUT", "moments", 4) where p[1] == "profile" && p[3] == "signature":
            var all = s.read("moments-profiles.json") as? [String: [String: Any]] ?? [:]
            let sig = String((r.json["signature"] as? String ?? "").prefix(60))
            all[p[2], default: [:]]["signature"] = sig
            s.write("moments-profiles.json", all)
            return .json(["signature": sig])
        case ("PUT", "moments", 4) where p[1] == "profile" && p[3] == "cover":
            guard let f = r.form.files["file"]?.first, let img = UIImage(data: f.data),
                  let jpg = LocalBrain.jpeg(img, maxSide: 2000) else { return .error(400, String(localized: "图读不了")) }
            s.saveFile(jpg, name: "cover-\(p[2])")
            return .empty
        case ("GET", "moments", 4) where p[1] == "profile" && p[3] == "cover":
            guard let d = try? Data(contentsOf: s.fileURL("cover-\(p[2])")) else { return .error(404, String(localized: "还没有封面")) }
            return .data(d, mime: "image/jpeg")
        default: return nil
        }
    }

    // MARK: - 相册

    static func albumOut(_ a: [String: Any]) -> [String: Any] {
        let id = a["id"] as? Int ?? 0
        return ["id": id, "companion_id": a["companion_id"] ?? "", "source": a["source"] ?? "user", "taken_at": a["taken_at"] ?? "",
                "caption": a["caption"] ?? "", "felt": a["felt"] ?? "", "why": a["why"] ?? "", "thoughts": a["thoughts"] ?? "",
                "note": a["note"] ?? "", "batch": a["batch"] ?? NSNull(), "starred": a["starred"] ?? false, "secret": a["secret"] ?? false,
                "looking": a["looking"] ?? false, "url": "album/\(id)/image", "thumb": "album/\(id)/image?thumb=1"]
    }

    static func albumList(_ s: LocalStore, book: String, companion: String?) -> [[String: Any]] {
        s.collection("album").filter { a in
            if let companion, !companion.isEmpty, (a["companion_id"] as? String) != companion { return false }
            switch book {
            case "starred": return a["starred"] as? Bool ?? false
            case "secret": return a["secret"] as? Bool ?? false
            default: return !(a["secret"] as? Bool ?? false)
            }
        }.sorted { LocalStore.date($0["taken_at"]) > LocalStore.date($1["taken_at"]) }.map(albumOut)
    }

    /// 存一张进相册（你在相册里加的，或者你在聊天里发的）
    @discardableResult
    static func addPhoto(_ host: LocalHost, _ data: Data, companion: String, source: String, note: String = "", batch: String? = nil) -> [String: Any]? {
        guard let img = UIImage(data: data), let jpg = LocalBrain.jpeg(img, maxSide: 2400) else { return nil }
        let s = host.store
        let id = s.nextID("album")
        s.saveFile(jpg, name: "album-\(id)")
        let a: [String: Any] = ["id": id, "companion_id": companion, "file": "album-\(id)", "source": source,
                                "taken_at": LocalStore.iso(Date()), "note": note, "batch": batch ?? NSNull(),
                                "starred": false, "secret": false, "looking": source == "user"]
        s.saveCollection("album", s.collection("album") + [a])
        return a
    }

    static func albumAdd(_ host: LocalHost, _ r: LocalRequest) -> LocalResponse {
        let form = r.form
        let comp = (form.fields["companion_id"]).flatMap { $0.isEmpty ? nil : $0 } ?? (host.store.companions.first?["id"] as? String ?? "")
        let note = String((form.fields["note"] ?? "").prefix(500))
        let batch = UUID().uuidString.lowercased()
        let files = (form.files["files"] ?? []).prefix(9)
        guard !files.isEmpty else { return .error(400, String(localized: "选几张照片吧")) }
        let added = files.compactMap { addPhoto(host, $0.data, companion: comp, source: "user", note: note, batch: files.count > 1 ? batch : nil) }
        look(host, ids: added.compactMap { $0["id"] as? Int }, companion: comp, note: note)
        return .json(added.map(albumOut), status: 201)
    }

    /// 它看照片：写一句图注、当时的感觉、想说的话（用你的 key；配不上 key 就不看）
    static func look(_ host: LocalHost, ids: [Int], companion: String, note: String) {
        Task.detached {
            let s = host.store
            defer {
                var all = s.collection("album")
                for i in all.indices where ids.contains(all[i]["id"] as? Int ?? -1) { all[i]["looking"] = false }
                s.saveCollection("album", all)
            }
            guard let comp = s.companion(companion), let (provider, key) = host.quietRoute(for: comp),
                  !LiteConsent.book.needsAsk(provider) else { return }
            try? await Task.sleep(for: .seconds(20))
            let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
            let contact = LocalBrain.contact(comp, provider: provider)
            for id in ids {
                guard let ph = s.collection("album").first(where: { ($0["id"] as? Int) == id }),
                      let d = try? Data(contentsOf: s.fileURL(ph["file"] as? String ?? "")), let img = UIImage(data: d),
                      let jpeg = LocalBrain.jpeg(img, maxSide: 1024) else { continue }
                let ask = zh
                    ? "TA 把这张照片放进了你们的相册\(note.isEmpty ? "" : "，还写了一句：「\(note)」")。用你自己的口吻写三行，每行一个，不要别的：\n图注：（10 字以内）\n感觉：（一个词）\n想说：（一两句，对 TA 说）"
                    : "They added this photo to your shared album\(note.isEmpty ? "" : " with the note: \"\(note)\""). In your own voice, write exactly three lines:\nCaption: (under 8 words)\nFeeling: (one word)\nSay: (one or two sentences to them)"
                var req = Prompt.build(PromptInput(contact: contact, identity: contact.mainIdentity, history: [], lang: zh ? .zh : .en))
                req.turns = [ChatTurn(role: .user, text: ask, imageJPEG: jpeg)]
                req.maxTokens = 600
                var text = ""
                do { for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { return }
                func line(_ keys: [String]) -> String {
                    for l in text.split(separator: "\n") {
                        let t = l.trimmingCharacters(in: .whitespaces)
                        for k in keys where t.hasPrefix(k) {
                            return t.dropFirst(k.count).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                        }
                    }
                    return ""
                }
                var all = s.collection("album")
                if let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) {
                    all[i]["caption"] = line(["图注", "Caption"])
                    all[i]["felt"] = line(["感觉", "Feeling"])
                    all[i]["thoughts"] = line(["想说", "Say"])
                    all[i]["looking"] = false
                    s.saveCollection("album", all)
                }
            }
        }
    }

    // MARK: - 朋友圈

    static func names(_ host: LocalHost) -> [String: String] {
        var out: [String: String] = ["user": host.profile["name"] as? String ?? ""]
        for c in host.store.companions { out[c["id"] as? String ?? ""] = (c["persona"] as? [String: Any])?["name"] as? String ?? "" }
        return out
    }

    static func momentOut(_ m: [String: Any], _ nm: [String: String]) -> [String: Any] {
        let comments = m["comments"] as? [[String: Any]] ?? []
        let byID = Dictionary(comments.map { ($0["id"] as? Int ?? 0, $0) }, uniquingKeysWith: { a, _ in a })
        return ["id": m["id"] ?? 0, "author": m["author"] ?? "user", "name": nm[m["author"] as? String ?? ""] ?? "",
                "content": m["content"] ?? "", "images": (m["images"] as? [String] ?? []).count, "created_at": m["created_at"] ?? "",
                "likes": (m["likes"] as? [[String: Any]] ?? []).map { ["who": $0["who"] ?? "", "name": nm[$0["who"] as? String ?? ""] ?? ""] },
                "comments": comments.map { c in
                    ["id": c["id"] ?? 0, "author": c["author"] ?? "", "name": nm[c["author"] as? String ?? ""] ?? "",
                     "content": c["content"] ?? "", "reply_to": c["reply_to"] ?? NSNull(),
                     "reply_to_name": (c["reply_to"] as? Int).flatMap { byID[$0] }.flatMap { nm[$0["author"] as? String ?? ""] } ?? NSNull(),
                     "created_at": c["created_at"] ?? ""] as [String: Any]
                }]
    }

    static func feed(_ host: LocalHost, who: String?, before: Int?, limit: Int) -> [[String: Any]] {
        let nm = names(host)
        return host.store.collection("moments")
            .filter { (who == nil || ($0["author"] as? String) == who) && (before == nil || ($0["id"] as? Int ?? 0) < before!) }
            .sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
            .prefix(max(1, min(limit, 50))).map { momentOut($0, nm) }
    }

    static func activity(_ host: LocalHost, since: String?) -> [String: Any] {
        let at = since.map { LocalStore.date($0) } ?? .distantPast
        let nm = names(host)
        var items: [[String: Any]] = []
        var newPosts = 0
        for m in host.store.collection("moments") {
            let mine = (m["author"] as? String) == "user"
            if !mine, LocalStore.date(m["created_at"]) > at { newPosts += 1 }
            if mine {
                for l in m["likes"] as? [[String: Any]] ?? [] where (l["who"] as? String) != "user" && LocalStore.date(l["at"]) > at {
                    items.append(["kind": "like", "who": l["who"] ?? "", "name": nm[l["who"] as? String ?? ""] ?? "", "at": l["at"] ?? "",
                                  "moment_id": m["id"] ?? 0, "post": m["content"] ?? "", "content": NSNull()])
                }
            }
            let comments = m["comments"] as? [[String: Any]] ?? []
            for c in comments where (c["author"] as? String) != "user" && LocalStore.date(c["created_at"]) > at {
                let toMe = (c["reply_to"] as? Int).flatMap { r in comments.first { ($0["id"] as? Int) == r } }.map { ($0["author"] as? String) == "user" }
                    ?? mine
                guard toMe else { continue }
                items.append(["kind": "comment", "who": c["author"] ?? "", "name": nm[c["author"] as? String ?? ""] ?? "",
                              "at": c["created_at"] ?? "", "moment_id": m["id"] ?? 0, "post": m["content"] ?? "", "content": c["content"] ?? ""])
            }
        }
        items.sort { ($0["at"] as? String ?? "") > ($1["at"] as? String ?? "") }
        return ["count": items.count, "new_posts": newPosts, "items": Array(items.prefix(50))]
    }

    static func post(_ host: LocalHost, _ r: LocalRequest) -> LocalResponse {
        let form = r.form
        let content = (form.fields["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = host.store
        var files: [String] = []
        for f in (form.files["files"] ?? []).prefix(9) {
            guard let img = UIImage(data: f.data), let jpg = LocalBrain.jpeg(img, maxSide: 2000) else { continue }
            let name = "moment-\(UUID().uuidString.lowercased())"
            s.saveFile(jpg, name: name)
            files.append(name)
        }
        guard !content.isEmpty || !files.isEmpty else { return .error(400, String(localized: "说点什么，或者放张图")) }
        let m: [String: Any] = ["id": s.nextID("moment"), "author": "user", "content": String(content.prefix(1000)), "images": files,
                                "created_at": LocalStore.iso(Date()), "likes": [[String: Any]](), "comments": [[String: Any]]()]
        s.saveCollection("moments", s.collection("moments") + [m])
        drop(host, moment: m["id"] as? Int ?? 0, replyTo: nil)
        return .json(momentOut(m, names(host)), status: 201)
    }

    static func update(_ s: LocalStore, _ id: Int?, _ change: (inout [String: Any]) -> Void) -> [String: Any]? {
        var all = s.collection("moments")
        guard let id, let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return nil }
        change(&all[i])
        s.saveCollection("moments", all)
        return all[i]
    }

    static func like(_ host: LocalHost, _ id: Int?, _ liked: Bool) -> LocalResponse {
        guard let m = update(host.store, id, { m in
            var likes = (m["likes"] as? [[String: Any]] ?? []).filter { ($0["who"] as? String) != "user" }
            if liked { likes.append(["who": "user", "at": LocalStore.iso(Date())]) }
            m["likes"] = likes
        }) else { return .error(404, String(localized: "没有这条")) }
        return .json(momentOut(m, names(host)))
    }

    static func comment(_ host: LocalHost, _ id: Int?, _ b: [String: Any]) -> LocalResponse {
        let text = (b["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .error(400, String(localized: "写点什么吧")) }
        let cid = host.store.nextID("moment-comment")
        guard let m = update(host.store, id, { m in
            var cs = m["comments"] as? [[String: Any]] ?? []
            cs.append(["id": cid, "author": "user", "content": String(text.prefix(500)), "reply_to": b["reply_to"] ?? NSNull(),
                       "created_at": LocalStore.iso(Date())])
            m["comments"] = cs
        }) else { return .error(404, String(localized: "没有这条")) }
        drop(host, moment: id ?? 0, replyTo: cid)
        return .json(momentOut(m, names(host)), status: 201)
    }

    static func deleteComment(_ host: LocalHost, _ cid: Int?) -> LocalResponse {
        var all = host.store.collection("moments")
        for i in all.indices {
            let cs = all[i]["comments"] as? [[String: Any]] ?? []
            if cs.contains(where: { ($0["id"] as? Int) == cid && ($0["author"] as? String) == "user" }) {
                all[i]["comments"] = cs.filter { ($0["id"] as? Int) != cid }
                host.store.saveCollection("moments", all)
                return .empty
            }
        }
        return .error(404, String(localized: "没有这条评论（只能删自己的）"))
    }

    /// TA 过一会儿来：你发了动态 → 每个配了 key 的联系人 1～3 分钟后赞一下、留一句；你回了它的评论 → 它接一句。
    /// Lite 没有服务器，App 关着就等下次打开（这一版先只在 App 开着时来）。
    static func drop(_ host: LocalHost, moment id: Int, replyTo: Int?) {
        Task.detached {
            let s = host.store
            for comp in s.companions {
                guard let cid = comp["id"] as? String, let (provider, key) = host.quietRoute(for: comp),
                      !LiteConsent.book.needsAsk(provider) else { continue }
                guard let m = s.collection("moments").first(where: { ($0["id"] as? Int) == id }) else { return }
                let comments = m["comments"] as? [[String: Any]] ?? []
                if let replyTo {                      // 只回在它评论下面接的话
                    guard let mine = comments.first(where: { ($0["id"] as? Int) == replyTo }),
                          let parent = (mine["reply_to"] as? Int).flatMap({ r in comments.first { ($0["id"] as? Int) == r } }),
                          (parent["author"] as? String) == cid || (m["author"] as? String) == cid else { continue }
                }
                try? await Task.sleep(for: .seconds(Double.random(in: 60...180)))
                let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
                let contact = LocalBrain.contact(comp, provider: provider)
                let thread = comments.map { "\(names(host)[$0["author"] as? String ?? ""] ?? "")：\($0["content"] as? String ?? "")" }.joined(separator: "\n")
                let ask = zh
                    ? "TA 在朋友圈\(replyTo == nil ? "发了一条" : "回了你的评论")。\n动态：\(m["content"] as? String ?? "")\(thread.isEmpty ? "" : "\n评论区：\n\(thread)")\n\n用你的口吻写一句评论（朋友圈那种短短一句），只写这一句。"
                    : "They \(replyTo == nil ? "posted on their feed" : "replied to your comment").\nPost: \(m["content"] as? String ?? "")\(thread.isEmpty ? "" : "\nComments:\n\(thread)")\n\nWrite one short comment in your own voice. Only the comment."
                var req = Prompt.build(PromptInput(contact: contact, identity: contact.mainIdentity, history: [], lang: zh ? .zh : .en))
                req.turns = [ChatTurn(role: .user, text: ask)]
                req.maxTokens = 400
                var text = ""
                do { for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { continue }
                let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = update(s, id) { m in
                    if replyTo == nil {
                        var likes = m["likes"] as? [[String: Any]] ?? []
                        if !likes.contains(where: { ($0["who"] as? String) == cid }) { likes.append(["who": cid, "at": LocalStore.iso(Date())]) }
                        m["likes"] = likes
                    }
                    guard !said.isEmpty else { return }
                    var cs = m["comments"] as? [[String: Any]] ?? []
                    cs.append(["id": s.nextID("moment-comment"), "author": cid, "content": String(said.prefix(300)),
                               "reply_to": replyTo ?? NSNull(), "created_at": LocalStore.iso(Date())])
                    m["comments"] = cs
                }
            }
        }
    }
}
#endif
