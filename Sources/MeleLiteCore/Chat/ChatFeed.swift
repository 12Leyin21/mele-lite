import Foundation

public struct FeedItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text, thinking, image(String), sticker(String), deeds([String])
    }
    public let id: String
    public let messageID: String?
    public let mine: Bool
    public let kind: Kind
    public let text: String
    public let at: Date
    public let quote: String?
}

/// 存下来的消息 → 聊天页一行行显示什么。一轮 = 两条 TA 消息之间。
public enum ChatFeed {
    public static func items(_ msgs: [Message], milestones: [Milestone], peeks: [PeekLog], lang: Lang) -> [FeedItem] {
        let zh = lang == .zh
        let byID = Dictionary(msgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [FeedItem] = []
        // 按 TA 的消息切轮
        var turns: [(opener: Message?, rest: [Message])] = [(nil, [])]
        for m in msgs {
            if m.role == .user { turns.append((m, [])) } else { turns[turns.count - 1].rest.append(m) }
        }
        for (i, turn) in turns.enumerated() {
            if let u = turn.opener { out += mine(u, quote: quoteText(u.quoteOf, byID)) }
            var thought = false
            for a in turn.rest {
                if !thought, let t = a.thinking, !t.isEmpty {
                    out.append(FeedItem(id: a.id + ":t", messageID: a.id, mine: false, kind: .thinking, text: t, at: a.at, quote: nil))
                    thought = true
                }
                let q = quoteText(a.quoteOf, byID)
                if let s = a.stickerID {
                    // 表情包那条的正文是给模型看的「[表情包：描述]」，屏幕上只画图
                    out.append(FeedItem(id: a.id + ":stk", messageID: a.id, mine: false, kind: .sticker(s), text: a.text, at: a.at, quote: q))
                    continue
                }
                out.append(FeedItem(id: a.id + ":txt", messageID: a.id, mine: false, kind: .text, text: a.text, at: a.at, quote: q))
            }
            let start = turn.opener?.at ?? .distantPast
            let end = i + 1 < turns.count ? (turns[i + 1].opener?.at ?? .distantFuture) : .distantFuture
            let inTurn: (Date) -> Bool = { $0 >= start && $0 < end }
            var deeds: [(Date, String)] = milestones.filter { inTurn($0.at) }
                .map { ($0.at, (zh ? "立了里程碑：" : "Set a milestone: ") + $0.title) }
            deeds += peeks.filter { inTurn($0.at) }.map { ($0.at, peekLine($0, zh: zh)) }
            if !deeds.isEmpty {
                let lines = deeds.sorted { $0.0 < $1.0 }.map(\.1)
                let last = turn.rest.last?.at ?? turn.opener?.at ?? deeds[0].0
                out.append(FeedItem(id: "deeds:" + (turn.opener?.id ?? "start"), messageID: nil, mine: false,
                                    kind: .deeds(lines), text: "", at: last, quote: nil))
            }
        }
        return out
    }

    static func mine(_ u: Message, quote: String?) -> [FeedItem] {
        var out: [FeedItem] = []
        if let f = u.imageFile {
            out.append(FeedItem(id: u.id + ":img", messageID: u.id, mine: true, kind: .image(f), text: "", at: u.at, quote: nil))
        }
        if !u.text.isEmpty {
            out.append(FeedItem(id: u.id + ":txt", messageID: u.id, mine: true, kind: .text, text: u.text, at: u.at, quote: quote))
        }
        return out
    }

    static func quoteText(_ id: String?, _ byID: [String: Message]) -> String? {
        guard let id, let m = byID[id] else { return nil }
        return String(m.text.prefix(40))
    }

    static func peekLine(_ p: PeekLog, zh: Bool) -> String {
        if p.rooms.isEmpty { return zh ? "想翻你的手机，你没给" : "Asked to see your phone — you said no" }
        let names: [PeekRoom: (String, String)] = [.chats: ("聊天", "chats"), .lore: ("世界书", "lore"),
                                                   .stickers: ("表情包", "stickers"), .favorites: ("收藏", "favorites")]
        let list = PeekRoom.allCases.filter(p.rooms.contains).map { zh ? names[$0]!.0 : names[$0]!.1 }
        return zh ? "翻了你的手机：" + list.joined(separator: "、") : "Looked through your phone: " + list.joined(separator: ", ")
    }
}
