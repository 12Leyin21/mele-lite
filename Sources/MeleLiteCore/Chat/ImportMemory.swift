import Foundation

/// 搬家时挑记忆（10-05，设计 new-app docs/superpowers/specs/2026-10-05-chat-import-design.md 的 B）：
/// 旧聊天切成小块，便宜模型每块挑 0～5 条值得记住的事；没接记忆库时再把挑出来的压成一段「搬家笔记」。
public enum ImportMemory {
    public struct Picked: Equatable, Sendable {
        public let day: String      // YYYY-MM-DD，没写日期是 ""
        public let text: String
        public init(day: String, text: String) { self.day = day; self.text = text }
    }

    public static let chunkSize = 6000
    public static let notesLimit = 3000

    /// 一段对话切成几块文字记录：「〔日期〕」换天时插一行，TA 那侧写名字、它那侧写「我」
    public static func chunks(_ c: ImportedConversation, userName: String, size: Int = chunkSize,
                              timeZone: TimeZone = .current) -> [String] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = timeZone
        let who = userName.isEmpty ? "TA" : userName
        var out: [String] = [], cur = "", lastDay = ""
        for m in c.messages {
            let day = f.string(from: m.at)
            var line = ""
            if day != lastDay || cur.isEmpty { line += "〔\(day)〕\n" }
            line += (m.role == .user ? who : "我") + "：" + String(m.text.prefix(size / 2)) + "\n"
            if !cur.isEmpty && cur.count + line.count > size {
                out.append(cur)
                cur = "〔\(day)〕\n" + line.replacingOccurrences(of: "〔\(day)〕\n", with: "")
            } else {
                cur += line
            }
            lastDay = day
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func pickPrompt(_ transcript: String, name: String, userName: String, zh: Bool) -> String {
        let user = userName.isEmpty ? (zh ? "TA" : "them") : userName
        if zh {
            return """
            下面是\(name)（文中的「我」）和\(user)以前的一段聊天记录。挑出 0～5 件以后还值得记住的事：\(user)的经历、喜好、身边的人、你们之间的约定、重要的时刻。

            - 每件一行，格式：- YYYY-MM-DD｜一句话（日期照记录里的〔日期〕写）
            - 用第一人称写：\(name)写「我」，对方写「\(user)」
            - 记录里\(user)说的「我」是\(user)自己、「你」是我：写的时候要换过来（\(user)说「我爸……」→「\(user)的爸爸……」）
            - 提到\(user)就写「\(user)」，不用「他」「她」
            - 只写记录里真有的，不猜、不补；闲聊、客套、写代码的过程不算
            - 没有值得记的就只写：（没有）

            ⟪记录开始⟫
            \(transcript)
            ⟪记录结束⟫
            """
        }
        return """
        Below is an old chat between \(name) ("Me" in the log) and \(user). Pick 0–5 things still worth remembering: \(user)'s life, likes, people around them, promises between you, important moments.

        - One per line: - YYYY-MM-DD | one sentence (use the 〔date〕 in the log)
        - First person: \(name) is "I", the other person is "\(user)"
        - When \(user) says "I" in the log they mean themselves, and "you" means me: swap them (\(user): "my dad…" → "\(user)'s dad…")
        - Refer to \(user) by name, not "he" or "she"
        - Only what is in the log; no guessing. Small talk, pleasantries and coding sessions don't count
        - If nothing is worth keeping, write only: (none)

        ⟪log start⟫
        \(transcript)
        ⟪log end⟫
        """
    }

    /// 读回模型挑的：只认「- 」开头的行；「日期｜内容」拆开，没日期的 day 为空
    public static func parsePicked(_ reply: String) -> [Picked] {
        reply.split(whereSeparator: \.isNewline).compactMap { raw -> Picked? in
            var s = raw.trimmingCharacters(in: .whitespaces)
            guard let first = s.first, "-•*·".contains(first) else { return nil }
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if s.count >= 10, s.prefix(10).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                let day = String(s.prefix(10))
                let rest = s.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: " ｜|:：-—"))
                return rest.isEmpty ? nil : Picked(day: day, text: rest)
            }
            return s.isEmpty || s.contains("（没有）") || s == "(none)" ? nil : Picked(day: "", text: s)
        }
    }

    /// 没接记忆库：挑出来的 + 官方自己的记忆，压成一段 ≤ limit 字的搬家笔记（第一人称）
    public static func notesPrompt(_ picked: [Picked], extra: [String], source: ChatSource, name: String,
                                   userName: String, zh: Bool, limit: Int = notesLimit) -> String {
        let user = userName.isEmpty ? (zh ? "TA" : "them") : userName
        let app = source.appName
        let limit = limit * 4 / 5        // 真包（10-05）：要 3000 它写到 3900+，跟模型要少一点，clipNotes 再兜底
        let items = picked.map { "- " + ($0.day.isEmpty ? "" : "\($0.day)｜") + $0.text }.joined(separator: "\n")
        let more = extra.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if zh {
            return """
            \(name)和\(user)以前在 \(app) 上聊过很久。下面是从那些聊天里挑出来的事\(more.isEmpty ? "" : "，还有 \(app) 当时记下的关于\(user)的笔记")。把它们整理成一段 \(limit) 字以内的笔记，给\(name)以后翻：

            - 第一人称：\(name)写「我」，对方写「\(user)」；提到\(user)就写「\(user)」，不用「他」「她」
            - 按主题归拢（\(user)是什么样的人、身边的人、喜好、我们之间的事和约定），每个主题写成几句话，不要一天一行地罗列；重复的合并，时间写大概（「七月初」）
            - 一定写在 \(limit) 字以内：事情多就挑重要的，琐碎的舍掉
            - 只写下面有的，不补、不抒情，也不写「已合并」这类整理说明
            - 只输出笔记正文，不要标题和前言

            【挑出来的事】
            \(items.isEmpty ? "（无）" : items)
            \(more.isEmpty ? "" : "\n【\(app) 的笔记】\n\(more)")
            """
        }
        return """
        \(name) and \(user) talked for a long time on \(app). Below are things picked from those chats\(more.isEmpty ? "" : ", plus the notes \(app) kept about \(user)"). Turn them into one note of at most \(limit) characters for \(name) to look back on:

        - First person: \(name) is "I", the other person is "\(user)"; refer to \(user) by name, not "he" or "she"
        - Group by topic (who \(user) is, people around them, likes, things between us and promises); a few sentences per topic, not one line per day; merge repeats, keep rough dates ("early July")
        - Stay within \(limit) characters: if there's a lot, keep what matters and drop the small stuff
        - Only what's below; nothing added, nothing lyrical, no editing remarks like "merged above"
        - Output only the note, no title or preamble

        [Picked]
        \(items.isEmpty ? "(none)" : items)
        \(more.isEmpty ? "" : "\n[\(app)'s notes]\n\(more)")
        """
    }

    /// 模型没守住字数（10-05 真包：要 3000 写了 3900+，原来硬切在半句「小满说以」）：
    /// 留到 1.3 倍，再退回最后一个句末 / 换行；一个句末都没有就硬切
    public static func clipNotes(_ text: String, limit: Int = notesLimit) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = Int(Double(limit) * 1.3)
        guard t.count > cap else { return t }
        let head = String(t.prefix(cap))
        let ends = Set("。！？!?…」”\n")
        guard let cut = head.lastIndex(where: { ends.contains($0) }) else { return head }
        return String(head[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Claude 的「记忆」导出（memories-000.zip 里 memories/<uuid>.json）：conversations_memory + 各项目的 project_memories
public enum ClaudeMemories {
    public static func parse(_ data: Data) throws -> [String] {
        guard let json = (try? MiniZip.entry(in: data) { $0.hasSuffix(".json") && !$0.hasPrefix("conversations") }) ?? nil,
              let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              o["conversations_memory"] != nil || o["project_memories"] != nil else { return [] }
        var out: [String] = []
        if let s = o["conversations_memory"] as? String { out.append(s) }
        for (_, v) in (o["project_memories"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let s = v as? String { out.append(s) }
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
