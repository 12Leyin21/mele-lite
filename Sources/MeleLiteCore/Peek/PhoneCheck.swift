import Foundation

/// 查手机：TA 同意后，把给看的那几间拼成一段文字递给它。
/// - 永远不含它自己跟 TA 的聊天（那它本来就知道）。
/// - 只看主号那一侧：别人的小号聊天不给；它自己用小号身份时看不到聊天（那个「另一个人」的手机上没有这些）。
public enum PhoneCheck {
    public static func snapshot(store: LiteStore, stickers: StickerLibrary, viewer: Contact, viewerIdentity: Identity,
                                rooms: Set<PeekRoom>, lang: Lang, perChat: Int = 30) -> String {
        let zh = lang == .zh
        var parts: [String] = []
        if rooms.contains(.chats), viewerIdentity.isMain {
            for c in store.contacts() where c.id != viewer.id {
                let msgs = store.messages(contact: c.id, identity: c.mainIdentity.id).suffix(perChat)
                guard !msgs.isEmpty else { continue }
                let lines = msgs.map { "\($0.role == .user ? (zh ? "TA" : "Them") : c.name)：\($0.text)" }
                parts.append((zh ? "## 跟 \(c.name) 的聊天（最近 \(msgs.count) 句）\n" : "## Chat with \(c.name) (last \(msgs.count))\n") + lines.joined(separator: "\n"))
            }
        }
        if rooms.contains(.lore) {
            let titles = store.lore().filter(\.enabled).map(\.title)
            if !titles.isEmpty { parts.append((zh ? "## 世界书\n" : "## Lorebook\n") + titles.joined(separator: "、")) }
        }
        if rooms.contains(.stickers) {
            let caps = stickers.all().map(\.caption).filter { !$0.isEmpty }
            if !caps.isEmpty { parts.append((zh ? "## 表情包\n" : "## Stickers\n") + caps.joined(separator: "、")) }
        }
        if rooms.contains(.favorites) {
            let mains = Dictionary(uniqueKeysWithValues: store.contacts().map { ($0.id, $0.mainIdentity.id) })
            // 小号聊天里收藏的不给看（联系人已删的照给）
            let favs = store.favorites().filter { f in mains[f.contactID].map { $0 == f.identityID } ?? true }.map(\.text)
            if !favs.isEmpty { parts.append((zh ? "## 收藏\n" : "## Favorites\n") + favs.map { "· " + $0 }.joined(separator: "\n")) }
        }
        if parts.isEmpty { return zh ? "（翻了一圈，没找到什么）" : "(You looked around and found nothing much.)" }
        return parts.joined(separator: "\n\n")
    }
}
