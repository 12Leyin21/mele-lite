import Foundation

public struct PromptInput: Sendable {
    public var contact: Contact
    public var identity: Identity
    public var history: [Message]
    public var loreHits: [LoreEntry]
    public var stickers: [Sticker]
    public var peekResult: String?
    public var lang: Lang
    public var now: Date
    public var timeZone: TimeZone
    public var currentImage: Data?

    public init(contact: Contact, identity: Identity, history: [Message], loreHits: [LoreEntry] = [], stickers: [Sticker] = [],
                peekResult: String? = nil, lang: Lang, now: Date = Date(), timeZone: TimeZone = .current, currentImage: Data? = nil) {
        self.contact = contact; self.identity = identity; self.history = history; self.loreHits = loreHits
        self.stickers = stickers; self.peekResult = peekResult; self.lang = lang; self.now = now
        self.timeZone = timeZone; self.currentImage = currentImage
    }
}

/// 拼给模型的一整份：system = 底子 + 你是谁 + 人设 + 对面这个人 + 线上线下 + 表情包（不常变，缓存吃得住）；
/// context = 现在几点 + 世界书 + 翻到的东西（每轮变，贴在 TA 最新那句后面）；
/// turns = 最近的聊天（同一方连着的几条并成一段，太长从最早丢）。
public enum Prompt {
    public static func build(_ i: PromptInput, budgetChars: Int = 24000) -> ChatRequest {
        ChatRequest(system: system(i), turns: turns(i, budget: budgetChars), context: context(i))
    }

    /// 每轮会变的：现在几点、世界书命中、翻到的
    static func context(_ i: PromptInput) -> String {
        let zh = i.lang == .zh
        var parts = [(zh ? "现在是 " : "It's now ") + clock(i.now, i.timeZone, i.lang)]
        if !i.loreHits.isEmpty {
            parts.append((zh ? "## 世界书\n" : "## Lorebook\n") + i.loreHits.map { "### \($0.title)\n\($0.content)" }.joined(separator: "\n\n"))
        }
        if let p = i.peekResult { parts.append((zh ? "## 你翻到的\n" : "## What you found on their phone\n") + p) }
        return parts.joined(separator: "\n\n")
    }

    static func system(_ i: PromptInput) -> String {
        let zh = i.lang == .zh
        let c = i.contact, me = i.identity
        var parts = [Resources.text("base", i.lang)]
        parts.append((zh ? "你是 \(c.name)。\n" : "You are \(c.name).\n") + c.persona)
        var who: [String] = []
        if !me.userName.isEmpty { who.append((zh ? "名字：" : "Name: ") + me.userName) }
        if !me.aboutMe.isEmpty { who.append((zh ? "关于 TA：" : "About them: ") + me.aboutMe) }
        if !me.relationship.isEmpty { who.append((zh ? "你们的关系：" : "Your relationship: ") + me.relationship) }
        if !who.isEmpty { parts.append((zh ? "## 对面这个人\n" : "## The person you're talking to\n") + who.joined(separator: "\n")) }
        parts.append(Resources.mode(c.mode == .online ? "online" : "offline", i.lang))
        let caps = i.stickers.map(\.caption).filter { !$0.isEmpty }
        if !caps.isEmpty { parts.append((zh ? "## 你的表情包\n" : "## Your stickers\n") + caps.map { "- " + $0 }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    static func clock(_ d: Date, _ tz: TimeZone, _ lang: Lang) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: lang == .zh ? "zh_CN" : "en_US")
        f.dateFormat = lang == .zh ? "yyyy-MM-dd EEEE HH:mm" : "EEEE, d MMM yyyy, HH:mm"
        return f.string(from: d)
    }

    static func turns(_ i: PromptInput, budget: Int) -> [ChatTurn] {
        let byID = Dictionary(i.history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [ChatTurn] = []
        for m in i.history {
            var text = m.text
            if let q = m.quoteOf, let orig = byID[q] {
                text = (i.lang == .zh ? "（回复：\(orig.text.prefix(30))）\n" : "(Replying to: \(orig.text.prefix(30)))\n") + text
            }
            if let last = merged.last, last.role == m.role {
                merged[merged.count - 1].text += "\n\n" + text
            } else {
                merged.append(ChatTurn(role: m.role, text: text))
            }
        }
        // 从最早开始丢，直到总字数 ≤ budget；最后一段一定留着
        var total = merged.reduce(0) { $0 + $1.text.count }
        while merged.count > 1, total > budget {
            total -= merged.removeFirst().text.count
        }
        if merged.first?.role == .assistant {
            merged.insert(ChatTurn(role: .user, text: i.lang == .zh ? "（开始聊天）" : "(Chat started)"), at: 0)
        }
        if let img = i.currentImage, let li = merged.lastIndex(where: { $0.role == .user }) {
            merged[li].imageJPEG = img
        }
        return merged
    }
}

/// 读 Resources/{zh,en}/*.md
enum Resources {
    static func text(_ name: String, _ lang: Lang) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts/\(lang.rawValue)"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// modes.md 里 [online] / [offline] / [letter] 各一段
    static func mode(_ key: String, _ lang: Lang) -> String {
        let all = text("modes", lang)
        var out: [String: String] = [:], cur = ""
        for line in all.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), line.hasSuffix("]") { cur = String(line.dropFirst().dropLast()); continue }
            out[cur, default: ""] += (out[cur, default: ""].isEmpty ? "" : "\n") + line
        }
        return out[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
