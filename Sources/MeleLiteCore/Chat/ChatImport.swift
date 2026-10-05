import Foundation

/// 导入官方 App 的聊天记录（10-05，设计 new-app docs/superpowers/specs/2026-10-05-chat-import-design.md）。
/// 读官方「导出数据」给的包（.zip，或者解压后的 conversations.json），认出是哪家，拆成一段段对话。
/// 只留文字：系统消息、工具、思考、图片 / 文件（导出里只有文件名）都不要；没有字的对话不要。
public enum ChatSource: String, Sendable, CaseIterable {
    case chatgpt, claude, deepseek, gemini
    public var appName: String {
        switch self { case .chatgpt: "ChatGPT"; case .claude: "Claude"; case .deepseek: "DeepSeek"; case .gemini: "Gemini" }
    }
}

/// needsJSON：Google Takeout 选成了 HTML（默认就是 HTML），要回去改成 JSON 再导一次
public enum ChatImportError: Error, Equatable { case unrecognized, mixed, needsJSON }

public struct ImportedMessage: Equatable, Sendable {
    public let role: Role
    public let text: String
    public let at: Date
    public init(role: Role, text: String, at: Date) { self.role = role; self.text = text; self.at = at }
}

public struct ImportedConversation: Equatable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let messages: [ImportedMessage]
    public init(id: String, title: String, createdAt: Date, messages: [ImportedMessage]) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.messages = messages
    }
    public var chars: Int { messages.reduce(0) { $0 + $1.text.count } }
}

public enum TimelineItem: Equatable, Sendable {
    case divider(title: String, at: Date)       // 每段开头那行灰字
    case message(ImportedMessage)
}

public enum ChatImport {
    /// 好几个包一起（Claude 10 月起分包给：conversations-000.zip、-001.zip……）：合起来、同一段只留一次；两家混着不行
    public static func parse(_ files: [Data]) throws -> (source: ChatSource, conversations: [ImportedConversation]) {
        var source: ChatSource?, out: [ImportedConversation] = [], seen = Set<String>()
        for f in files {
            let got = try parse(f)
            if let s = source, s != got.source { throw ChatImportError.mixed }
            source = got.source
            for c in got.conversations where seen.insert(c.id).inserted { out.append(c) }
        }
        guard let source else { throw ChatImportError.unrecognized }
        return (source, out)
    }

    public static func parse(_ data: Data, timeZone: TimeZone = .current) throws -> (source: ChatSource, conversations: [ImportedConversation]) {
        if let takeout = try gemini(zip: data, timeZone: timeZone) { return (.gemini, takeout) }
        // 包里的文件叫 conversations.json，或者带编号 conversations-000.json
        let json = (try? MiniZip.entry(in: data) { $0.hasPrefix("conversations") && $0.hasSuffix(".json") }).flatMap { $0 } ?? data
        guard let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { throw ChatImportError.unrecognized }
        if arr.contains(where: isGeminiRecord) {
            return (.gemini, gemini(arr, timeZone: timeZone))
        }
        // DeepSeek 也有 mapping（照 ChatGPT 学的），但根叫 "root"、没有 current_node：要先认它
        if arr.contains(where: { ($0["mapping"] as? [String: Any])?["root"] != nil && $0["current_node"] == nil }) {
            return (.deepseek, arr.compactMap(deepSeek).filter { !$0.messages.isEmpty })
        }
        if arr.contains(where: { $0["mapping"] is [String: Any] }) {
            return (.chatgpt, arr.compactMap(chatGPT).filter { !$0.messages.isEmpty })
        }
        if arr.contains(where: { $0["chat_messages"] is [Any] }) {
            return (.claude, arr.compactMap(claude).filter { !$0.messages.isEmpty })
        }
        throw ChatImportError.unrecognized
    }

    /// 几段按时间合成一条：早的那段在前，每段开头一行分隔
    public static func timeline(_ convs: [ImportedConversation], source: ChatSource) -> [TimelineItem] {
        convs.sorted { ($0.messages.first?.at ?? $0.createdAt) < ($1.messages.first?.at ?? $1.createdAt) }.flatMap { c in
            [TimelineItem.divider(title: c.title, at: c.messages.first?.at ?? c.createdAt)] + c.messages.map(TimelineItem.message)
        }
    }

    // MARK: ChatGPT：mapping 是一棵树，从 current_node 顺着 parent 往回走 = 用户最后看到的那条分支

    static func chatGPT(_ c: [String: Any]) -> ImportedConversation? {
        guard let mapping = c["mapping"] as? [String: [String: Any]] else { return nil }
        let created = date(c["create_time"]) ?? Date(timeIntervalSince1970: 0)
        var node = c["current_node"] as? String
        var seen = Set<String>(), out: [ImportedMessage] = []
        while let id = node, let n = mapping[id], seen.insert(id).inserted {
            if let m = n["message"] as? [String: Any],
               let role = ((m["author"] as? [String: Any])?["role"] as? String).flatMap(Role.init(rawValue:)),
               let content = m["content"] as? [String: Any] {
                let text = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
                if !text.isEmpty { out.append(ImportedMessage(role: role, text: text, at: date(m["create_time"]) ?? created)) }
            }
            node = n["parent"] as? String
        }
        return ImportedConversation(id: c["id"] as? String ?? c["conversation_id"] as? String ?? UUID().uuidString,
                                    title: c["title"] as? String ?? "", createdAt: created, messages: out.reversed())
    }

    // MARK: Claude：chat_messages 按顺序；正文优先 content 里的 text 块，没有就用 text

    static func claude(_ c: [String: Any]) -> ImportedConversation? {
        guard let msgs = c["chat_messages"] as? [[String: Any]] else { return nil }
        let created = date(c["created_at"]) ?? Date(timeIntervalSince1970: 0)
        let out = msgs.compactMap { m -> ImportedMessage? in
            let role: Role? = switch m["sender"] as? String { case "human": .user; case "assistant": .assistant; default: nil }
            guard let role else { return nil }
            let blocks = (m["content"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == "text" }
            let text = (blocks.isEmpty ? (m["text"] as? String ?? "") : blocks.compactMap { $0["text"] as? String }.joined())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ImportedMessage(role: role, text: text, at: date(m["created_at"]) ?? created)
        }
        return ImportedConversation(id: c["uuid"] as? String ?? UUID().uuidString, title: c["name"] as? String ?? "",
                                    createdAt: created, messages: out)
    }

    // MARK: DeepSeek（设置 → 数据管理 → 导出所有历史对话）：conversations.json，mapping 从 "root" 往下长；
    // 每条的字在 fragments 里：REQUEST 是人说的，RESPONSE 是它答的，THINK（深度思考）、SEARCH（联网）不要。
    // 重新生成 / 改过问题会分叉：每一步走最新的那个孩子（≈ 用户最后看到的）

    static func deepSeek(_ c: [String: Any]) -> ImportedConversation? {
        guard let mapping = c["mapping"] as? [String: [String: Any]] else { return nil }
        let created = date(c["inserted_at"]) ?? Date(timeIntervalSince1970: 0)
        func at(_ id: String) -> Date { date((mapping[id]?["message"] as? [String: Any])?["inserted_at"]) ?? .distantPast }
        var node: String? = "root", seen = Set<String>(), out: [ImportedMessage] = []
        while let id = node, let n = mapping[id], seen.insert(id).inserted {
            if let m = n["message"] as? [String: Any] {
                let frags = m["fragments"] as? [[String: Any]] ?? []
                for role in [Role.user, .assistant] {
                    let type = role == .user ? "REQUEST" : "RESPONSE"
                    let text = frags.filter { ($0["type"] as? String) == type }.compactMap { $0["content"] as? String }
                        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(ImportedMessage(role: role, text: text, at: date(m["inserted_at"]) ?? created)) }
                }
            }
            let kids = n["children"] as? [String] ?? []
            node = kids.enumerated().max { (at($0.element), $0.offset) < (at($1.element), $1.offset) }?.element
        }
        return ImportedConversation(id: c["id"] as? String ?? UUID().uuidString, title: c["title"] as? String ?? "",
                                    createdAt: created, messages: out)
    }

    // MARK: Gemini（Google Takeout → 我的活动 → Gemini Apps，格式选 JSON）
    // 不是一段段对话，是一条条活动：title「Prompted 问的话」+ safeHtmlItem 里它答的 HTML，前后没有关联。
    // 照别人对真包的核对（一份 875 条）：Prompted / Branched / Answered 是问答；Created（Canvas）、Added、Used、Gave（反馈）不是。
    // 没法还原成原来的对话，就按天合成一段（「Gemini · 2025-09-20」）。

    static let geminiAsked = ["Prompted ", "Branched ", "Answered "]
    static let geminiNotChat = ["Created ", "Added ", "Used ", "Gave "]

    static func isGeminiRecord(_ r: [String: Any]) -> Bool {
        guard r["safeHtmlItem"] != nil || r["title"] is String else { return false }
        let tags = [r["header"] as? String ?? ""] + (r["products"] as? [String] ?? [])
        return tags.contains { $0.hasPrefix("Gemini") }
    }

    /// Takeout 的包：路径里有 Gemini 的 .json；只有 .html 就是格式选错了
    static func gemini(zip data: Data, timeZone: TimeZone) throws -> [ImportedConversation]? {
        guard let files = try? MiniZip.entries(in: data, path: { $0.contains("Gemini") && ($0.hasSuffix(".json") || $0.hasSuffix(".html")) }),
              !files.isEmpty else { return nil }
        let records = files.filter { $0.path.hasSuffix(".json") }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.data) as? [[String: Any]] }
            .flatMap { $0 }.filter(isGeminiRecord)
        if records.isEmpty {
            if files.contains(where: { $0.path.hasSuffix(".html") }) { throw ChatImportError.needsJSON }
            return nil
        }
        return gemini(records, timeZone: timeZone)
    }

    static func gemini(_ records: [[String: Any]], timeZone: TimeZone) -> [ImportedConversation] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = timeZone
        var days: [String: [ImportedMessage]] = [:]
        for r in records where isGeminiRecord(r) {
            guard let at = date(r["time"]) else { continue }
            var ask = r["title"] as? String ?? ""
            if geminiNotChat.contains(where: ask.hasPrefix) { continue }
            if let verb = geminiAsked.first(where: ask.hasPrefix) { ask.removeFirst(verb.count) }
            ask = ask.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (r["safeHtmlItem"] as? [[String: Any]] ?? []).compactMap { $0["html"] as? String }
                .map(plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !ask.isEmpty, !answer.isEmpty else { continue }      // 只发了图的（title 只剩动词）、没回答的不要
            let day = f.string(from: at)
            days[day, default: []] += [ImportedMessage(role: .user, text: ask, at: at),
                                       ImportedMessage(role: .assistant, text: answer, at: at.addingTimeInterval(0.001))]
        }
        return days.keys.sorted().map { day in
            let msgs = days[day]!.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
            return ImportedConversation(id: "gemini-\(day)", title: "Gemini · \(day)", createdAt: msgs[0].at, messages: msgs)
        }
    }

    /// Gemini 回答是 HTML：分段 / 换行 / 列表变成换行，标签去掉，常见实体还原
    static func plainText(_ html: String) -> String {
        var t = html
        let rules: [(String, String)] = [
            (#"(?i)<br\s*/?>"#, "\n"), (#"(?i)<li[^>]*>"#, "\n- "),
            (#"(?i)</(p|div|h[1-6]|ul|ol|pre|blockquote|tr)>"#, "\n"), (#"<[^>]+>"#, ""),
        ]
        for (pattern, with) in rules { t = t.replacingOccurrences(of: pattern, with: with, options: .regularExpression) }
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        t = t.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 秒数（ChatGPT）或 ISO 时间（Claude，可能带六位小数）
    static func date(_ v: Any?) -> Date? {
        if let n = v as? Double { return Date(timeIntervalSince1970: n) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n)) }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // 小数超过三位 ISO8601DateFormatter 不认：拆开自己加
        guard let dot = s.firstIndex(of: "."), let z = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
              let base = f.date(from: String(s[..<dot]) + String(s[z...])), let frac = Double("0" + s[dot..<z]) else { return nil }
        return base.addingTimeInterval(frac)
    }
}
