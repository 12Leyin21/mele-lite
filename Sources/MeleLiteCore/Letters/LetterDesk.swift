import Foundation

/// 打开 App 时它可能给你留了一封信：上一封之后聊过天、且离上一封至少 20 小时，才写。
public enum LetterDesk {
    public static let gap: TimeInterval = 20 * 3600

    public static func shouldWrite(lastLetter: Date?, lastChat: Date?, now: Date) -> Bool {
        guard let lastChat else { return false }
        guard let lastLetter else { return true }
        return lastChat > lastLetter && now.timeIntervalSince(lastLetter) >= gap
    }

    /// 写信那一轮的请求：平时的聊天当底子，末尾加一句「写信」的说明
    public static func request(contact: Contact, identity: Identity, history: [Message], loreHits: [LoreEntry],
                               lang: Lang, now: Date = Date()) -> ChatRequest {
        var h = history
        h.append(Message(role: .user, text: Resources.mode("letter", lang), at: now))
        var req = Prompt.build(PromptInput(contact: contact, identity: identity, history: h, loreHits: loreHits, lang: lang, now: now))
        req.maxTokens = 4000
        return req
    }

    /// 回来的字：第一行是标题，其余是正文
    public static func parse(_ text: String, lang: Lang) -> (title: String, body: String) {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = lines.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#《》 \t")) } ?? ""
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (title.isEmpty ? (lang == .zh ? "给你的信" : "A letter for you") : title, body)
    }

    /// 用这个身份的聊天当底子写一封，存进本机
    public static func write(contact: Contact, identity: Identity, store: LiteStore, client: LLMClient,
                             lang: Lang, now: Date = Date()) async throws -> Letter {
        let history = store.messages(contact: contact.id, identity: identity.id)
        let req = request(contact: contact, identity: identity, history: history,
                          loreHits: LoreMatcher.hits(entries: store.lore(), recent: history, contactID: contact.id), lang: lang, now: now)
        var text = ""
        for try await e in client.stream(req) { if case .text(let t) = e { text += t } }
        let (title, body) = parse(text, lang: lang)
        let letter = Letter(contactID: contact.id, identityID: identity.id, title: title, body: body, at: now)
        try store.saveLetter(letter)
        return letter
    }
}
