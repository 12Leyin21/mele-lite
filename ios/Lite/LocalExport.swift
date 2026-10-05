#if LITE
import CryptoKit
import Foundation

/// 搬家包（10-04 Mele Host 第三步）：手机里的东西打成一包，交给 Host 的 /me/import（server/brain/host_import.py）。
/// 第一版搬核心：我的设定、模型钥匙（原文，走 HTTPS 交给自己的 Host）、联系人（人设、设置、头像、用哪把钥匙）、平常窗口的聊天。
/// 无痕窗口和小号窗口不搬（Host 还没有小号）。10-05 加了第一批房间（纯文字的八样）和第二批（带文件的：相册、表情包、书架、饮食、朋友圈、塔罗）。
/// 带文件的：条目里只写文件指纹（sha256），文件另外一个个传（HostLink.moveFromPhone）。里程碑 10-05 也上了 Host，一起搬。手机里的原件一个不删。
enum LocalExport {
    static let version = 1
    static let roomKinds = ["diary", "drawer", "dates", "todos", "wallet", "people", "lore", "favorites", "milestones"]

    static func hostBundle(_ host: LocalHost = .shared) -> [String: Any] { hostBundle(host, withFiles: false).bundle }

    /// withFiles：连带第二批房间，并返回 {指纹: 手机里的文件}（要读每个文件算指纹，别在主线程调）
    static func hostBundle(_ host: LocalHost = .shared, withFiles: Bool) -> (bundle: [String: Any], files: [String: URL]) {
        let s = host.store
        let keys: [[String: Any]] = host.keys.compactMap { k in
            guard let id = k["id"] as? String, let secret = host.vault.get(id) else { return nil }
            var out: [String: Any] = ["local_id": id, "provider": k["provider"] ?? "", "chat_model": k["chat_model"] ?? "",
                                      "api_key": secret]
            if let b = k["base_url"] as? String, !b.isEmpty { out["base_url"] = b }
            return out
        }
        let companions: [[String: Any]] = s.companions.compactMap { c in
            guard let cid = c["id"] as? String else { return nil }
            let convs: [[String: Any]] = s.conversations.filter {
                ($0["companion_id"] as? String) == cid && ($0["incognito"] as? Bool) != true && $0["alt"] == nil
            }.compactMap { v in
                guard let vid = v["id"] as? String else { return nil }
                let msgs: [[String: Any]] = s.messages(vid).compactMap { m in
                    guard let role = m["role"] as? String, role == "user" || role == "assistant" else { return nil }
                    var out: [String: Any] = ["role": role, "text": m["text"] as? String ?? "",
                                              "thinking": m["thinking"] as? String ?? "", "at": m["at"] as? String ?? ""]
                    if let ms = m["thinking_ms"] as? Int { out["thinking_ms"] = ms }
                    return out
                }
                return ["id": vid, "messages": msgs]
            }
            var out: [String: Any] = ["id": cid, "persona": c["persona"] ?? [String: Any](), "settings": c["settings"] ?? [String: Any](),
                                      "conversations": convs]
            if let k = c["key_id"] as? String { out["key_local_id"] = k }
            if let d = try? Data(contentsOf: s.fileURL("avatar-\(cid).jpg")) { out["avatar_b64"] = d.base64EncodedString() }
            return out
        }
        // 房间（10-05 第一批）：手机本来就照服务器的形状存，原样带上，服务器那边翻译；TA 的日记不搬（Host 上 TA 自己写）
        var rooms: [String: Any] = [:]
        for kind in roomKinds { rooms[kind] = s.collection(kind) }
        rooms["diary"] = s.collection("diary").filter { ($0["author"] as? String) == "user" }
        var files: [String: URL] = [:]
        if withFiles { fileRooms(s, into: &rooms, files: &files) }
        return (["version": version, "profile": host.profile, "keys": keys, "companions": companions, "rooms": rooms], files)
    }

    /// 第二批（10-05）：照服务器 host_import 的 FILE_KINDS，每条带上要用的文件指纹
    static func fileRooms(_ s: LocalStore, into rooms: inout [String: Any], files: inout [String: URL]) {
        func sha(_ name: String) -> String? {
            guard !name.isEmpty else { return nil }
            let url = s.fileURL(name)
            guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            files[h] = url
            return h
        }
        rooms["album"] = s.collection("album").map { a in
            var a = a; a["sha"] = sha(a["file"] as? String ?? "") ?? NSNull(); return a
        }
        rooms["stickers"] = s.collection("stickers").map { st in
            var st = st; st["sha"] = sha(st["file"] as? String ?? "") ?? NSNull(); return st
        }
        rooms["books"] = s.collection("books").map { b in
            var b = b
            b["text_sha"] = sha(b["file"] as? String ?? "") ?? NSNull()
            b["cover_sha"] = sha("book-cover-\(b["id"] as? Int ?? 0)") ?? NSNull()
            return b
        }
        rooms["book-marks"] = s.collection("book-marks")
        rooms["book-reading"] = s.collection("book-reading").map { r in
            var r = r; r["id"] = "\(r["book_id"] as? Int ?? 0):\(r["day"] as? String ?? "")"; return r
        }
        rooms["food"] = s.collection("food").map { e in
            var e = e, shas: [String: String] = [:]
            for p in e["photo_ids"] as? [String] ?? [] { shas[p] = sha("att-\(p)") }
            e["photo_shas"] = shas
            return e
        }
        rooms["food-covers"] = ((s.read("food-covers.json") as? [String: String]) ?? [:]).map { day, att in
            ["id": day, "day": day, "photo_id": att]
        }
        rooms["moments"] = s.collection("moments").map { m in
            var m = m; m["image_shas"] = (m["images"] as? [String] ?? []).compactMap { sha($0) }; return m
        }
        let profiles = s.read("moments-profiles.json") as? [String: [String: Any]] ?? [:]
        rooms["moment-profiles"] = (["user"] + s.companions.compactMap { $0["id"] as? String }).compactMap { who -> [String: Any]? in
            let sig = profiles[who]?["signature"] as? String ?? ""
            let cover = sha("cover-\(who)")
            guard !sig.isEmpty || cover != nil else { return nil }
            return ["id": who, "who": who, "signature": sig, "cover_sha": cover ?? NSNull()]
        }
        rooms["tarot"] = s.collection("tarot")
    }

    /// 包里有多少（搬之前给人看一眼）
    static func summary(_ b: [String: Any]) -> (companions: Int, messages: Int) {
        let comps = b["companions"] as? [[String: Any]] ?? []
        let msgs = comps.reduce(0) { n, c in
            n + (c["conversations"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["messages"] as? [Any])?.count ?? 0) }
        }
        return (comps.count, msgs)
    }
}
#endif
