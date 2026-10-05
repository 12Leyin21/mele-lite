#if LITE
import Foundation

/// 搬家包（10-04 Mele Host 第三步）：手机里的东西打成一包，交给 Host 的 /me/import（server/brain/host_import.py）。
/// 第一版搬核心：我的设定、模型钥匙（原文，走 HTTPS 交给自己的 Host）、联系人（人设、设置、头像、用哪把钥匙）、平常窗口的聊天。
/// 无痕窗口和小号窗口不搬（Host 还没有小号）；房间（日记、相册、书架……）以后一样样加。手机里的原件一个不删。
enum LocalExport {
    static let version = 1

    static func hostBundle(_ host: LocalHost = .shared) -> [String: Any] {
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
        return ["version": version, "profile": host.profile, "keys": keys, "companions": companions]
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
