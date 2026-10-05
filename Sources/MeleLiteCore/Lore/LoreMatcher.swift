import Foundation

/// 世界书：最近几句里说到关键词才把那一条递给它；常驻的总在。
public enum LoreMatcher {
    public static func hits(entries: [LoreEntry], recent: [Message], contactID: String,
                            scan: Int = 4, maxHits: Int = 8) -> [LoreEntry] {
        let haystack = normalize(recent.suffix(scan).map(\.text).joined(separator: "\n"))
        var out: [LoreEntry] = []
        for e in entries where e.enabled && (e.contactIDs == nil || e.contactIDs!.contains(contactID)) {
            if e.constant || e.keys.contains(where: { k in
                let n = normalize(k)
                return !n.isEmpty && haystack.contains(n)
            }) {
                out.append(e)
                if out.count == maxHits { break }
            }
        }
        return out
    }

    /// 全角转半角、大小写不分
    static func normalize(_ s: String) -> String {
        (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).lowercased()
    }
}
