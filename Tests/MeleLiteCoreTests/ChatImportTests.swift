import Foundation
import Testing
@testable import MeleLiteCore

/// 导入官方聊天记录（10-05，设计 new-app docs/superpowers/specs/2026-10-05-chat-import-design.md）。假导出包是小满 / Mia。
@Suite struct ChatImportTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func zipFindsConversationsInDeflatedAndStoredArchives() throws {
        for name in ["chatgpt-export.zip", "claude-export.zip"] {
            let json = try #require(try MiniZip.entry("conversations.json", in: fixture(name)))
            #expect((try JSONSerialization.jsonObject(with: json) as? [Any])?.count == 2)
        }
        #expect(try MiniZip.entry("nope.json", in: fixture("claude-export.zip")) == nil)
    }

    @Test func chatGPTFollowsTheBranchTheyLastSaw() throws {
        let got = try ChatImport.parse(fixture("chatgpt-export.zip"))
        #expect(got.source == .chatgpt)
        let beach = try #require(got.conversations.first { $0.title == "周末去哪" })
        #expect(beach.messages.map(\.text) == ["周末想去海边，你觉得呢", "去吧，记得带外套", "这是那天拍的", "好看。\n风大吗"])
        #expect(beach.messages.map(\.role) == [.user, .assistant, .user, .assistant])   // 系统、工具、被重新生成掉的都不要
        #expect(beach.messages[0].at == Date(timeIntervalSince1970: 1727000010))
        #expect(beach.createdAt == Date(timeIntervalSince1970: 1727000000))
    }

    @Test func claudeUsesContentTextAndFallsBackToText() throws {
        let got = try ChatImport.parse(fixture("claude-export.zip"))
        #expect(got.source == .claude)
        #expect(got.conversations.count == 1)                                     // 空对话不要
        let c = got.conversations[0]
        #expect(c.title == "睡不着")
        #expect(c.messages.map(\.text) == ["睡不着，陪我聊会儿", "好，我在", "只有 text 字段的老格式"])   // 思考、只调工具的不要
        #expect(c.messages.map(\.role) == [.user, .assistant, .user])
        #expect(abs(c.messages[1].at.timeIntervalSince(ISO8601DateFormatter().date(from: "2025-09-20T14:00:09Z")!) - 0.123456) < 0.001)
    }

    @Test func deepSeekWalksFromRootTakingTheNewestBranch() throws {
        let got = try ChatImport.parse(fixture("deepseek-export.zip"))
        #expect(got.source == .deepseek)                                              // 有 mapping 也不能认成 ChatGPT
        #expect(got.conversations.count == 1)                                         // 空对话不要
        let c = got.conversations[0]
        #expect(c.title == "周末去哪")
        #expect(c.messages.map(\.text) == ["周末想去海边，你觉得呢", "去吧，记得带外套", "风大吗", "有点大，戴帽子"])   // 思考、联网、旧分支不要
        #expect(c.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(c.messages[0].at == ISO8601DateFormatter().date(from: "2025-09-20T06:00:01Z"))
    }

    @Test func geminiTakeoutIsGroupedByDayAndOnlyKeepsQuestions() throws {
        let got = try ChatImport.parse(fixture("gemini-takeout.zip"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(got.source == .gemini)
        #expect(got.conversations.map(\.title) == ["Gemini · 2025-09-20", "Gemini · 2025-09-21"])   // YouTube 那份不算
        let first = got.conversations[0]
        #expect(first.messages.map(\.text) == ["养猫要准备什么", "猫砂盆\n\n猫粮和水碗", "那狗呢", "狗要\n牵引绳"])  // 只发图、Canvas、反馈不要
        #expect(first.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(got.conversations[1].messages[1].text == "要的，早晚凉。\n\n- 薄外套\n- 围巾 & 帽子")
    }

    @Test func geminiHTMLTakeoutAsksForJSON() throws {
        #expect(throws: ChatImportError.needsJSON) { try ChatImport.parse(fixture("gemini-takeout-html.zip")) }
    }

    @Test func plainJSONWorksToo() throws {
        let json = try #require(try MiniZip.entry("conversations.json", in: fixture("claude-export.zip")))
        #expect(try ChatImport.parse(json).source == .claude)
    }

    @Test func unknownFileIsRejected() {
        #expect(throws: ChatImportError.unrecognized) { try ChatImport.parse(Data("[{\"foo\":1}]".utf8)) }
        #expect(throws: ChatImportError.unrecognized) { try ChatImport.parse(Data("not json".utf8)) }
    }

    @Test func timelineMergesByTimeWithADividerPerConversation() throws {
        let got = try ChatImport.parse(fixture("chatgpt-export.zip"))
        let t = ChatImport.timeline(got.conversations, source: got.source)
        guard case let .divider(first, _) = t[0] else { Issue.record("第一条应该是分隔行"); return }
        #expect(first == "考试")                                                 // 早的那段在前
        #expect(t.filter { if case .divider = $0 { return true } else { return false } }.count == 2)
        #expect(t.count == 2 + 2 + 4)
    }
}

@Suite struct ChatImportSplitTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func numberedConversationFileInsideAFolderIsFound() throws {
        let got = try ChatImport.parse(fixture("claude-part1.zip"))
        #expect(got.source == .claude && got.conversations.map(\.title) == ["第二包里的"])
    }

    @Test func severalPackagesAreMergedAndDeduped() throws {
        let got = try ChatImport.parse([fixture("claude-export.zip"), fixture("claude-part1.zip"), fixture("claude-export.zip")])
        #expect(got.source == .claude)
        #expect(Set(got.conversations.map(\.title)) == ["睡不着", "第二包里的"])
    }

    @Test func mixingTwoAppsIsRejected() {
        #expect(throws: ChatImportError.mixed) {
            try ChatImport.parse([try fixture("claude-export.zip"), try fixture("chatgpt-export.zip")])
        }
    }
}

@Suite struct ImportMemoryTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func claudeMemoriesAreRead() throws {
        #expect(try ClaudeMemories.parse(fixture("claude-memories.zip")) == ["小满在读高三，喜欢秋天。", "小满养了一只橘猫叫年糕。"])
        #expect(try ClaudeMemories.parse(fixture("claude-export.zip")).isEmpty)          // 不是记忆包
    }

    @Test func chunksKeepSpeakersAndDatesAndStayUnderSize() {
        let day = ISO8601DateFormatter().date(from: "2025-09-20T14:00:00Z")!
        let msgs = (0..<30).map { i in
            ImportedMessage(role: i % 2 == 0 ? .user : .assistant, text: String(repeating: "字", count: 300), at: day.addingTimeInterval(Double(i) * 60))
        }
        let c = ImportedConversation(id: "c", title: "睡不着", createdAt: day, messages: msgs)
        let chunks = ImportMemory.chunks(c, userName: "小满", size: 2000, timeZone: TimeZone(identifier: "UTC")!)
        #expect(chunks.count > 1 && chunks.allSatisfy { $0.count <= 2000 + 400 })
        #expect(chunks[0].hasPrefix("〔2025-09-20〕") && chunks[0].contains("小满：") && chunks[0].contains("我："))
    }

    @Test func pickedLinesAreParsedAndJunkDropped() {
        let reply = """
        - 2025-09-20｜小满养了一只橘猫叫年糕
        - 2025-09-21 | 我们说好十二月一起看雪
        - 没有日期的一条
        无关的废话
        （没有值得记的）
        """
        let got = ImportMemory.parsePicked(reply)
        #expect(got.map(\.day) == ["2025-09-20", "2025-09-21", ""])
        #expect(got.map(\.text) == ["小满养了一只橘猫叫年糕", "我们说好十二月一起看雪", "没有日期的一条"])
    }

    @Test func promptsSwapSpeakersAndAvoidGuessedPronouns() {
        let pick = ImportMemory.pickPrompt("〔2025-09-20〕\n小满：我爸说我是北方人", name: "Mia", userName: "小满", zh: true)
        #expect(pick.contains("「小满的爸爸……」") && pick.contains("不用「他」「她」"))
        let notes = ImportMemory.notesPrompt([.init(day: "2025-09-20", text: "小满的爸爸说她是北方人")], extra: [],
                                             source: .claude, name: "Mia", userName: "小满", zh: true)
        #expect(notes.contains("2400 字以内") && notes.contains("不写「已合并」"))
    }

    @Test func notesOverLimitAreClippedAtSentenceEnd() {
        let long = String(repeating: "小满喜欢吃饺子。", count: 600) + "小满说以"
        let got = ImportMemory.clipNotes(long, limit: 3000)
        #expect(got.count <= 3900 && got.hasSuffix("。"))
        #expect(ImportMemory.clipNotes("  短的  ", limit: 3000) == "短的")
        #expect(ImportMemory.clipNotes(String(repeating: "字", count: 5000), limit: 3000).count == 3900)
    }
}
