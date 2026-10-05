import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct PromptTests {
    func input(_ c: Contact, identity: Identity? = nil, history: [Message] = [], lore: [LoreEntry] = [],
               stickers: [Sticker] = [], peek: String? = nil, lang: Lang = .zh, image: Data? = nil) -> PromptInput {
        PromptInput(contact: c, identity: identity ?? c.mainIdentity, history: history, loreHits: lore, stickers: stickers,
                    peekResult: peek, lang: lang, now: Date(timeIntervalSince1970: 1_791_000_000), timeZone: TimeZone(identifier: "Asia/Singapore")!,
                    currentImage: image)
    }

    @Test func sectionsInOrder() {
        var c = sampleContact()
        c.identities[0].userName = "小满"
        c.identities[0].relationship = "恋人"
        let r = Prompt.build(input(c, history: [Message(role: .user, text: "在吗")],
                                   lore: [LoreEntry(title: "年糕", keys: ["年糕"], content: "她的橘猫")],
                                   stickers: [Sticker(sha: "a", file: "a.png", caption: "猫猫比心")], peek: "## 表情包\n狗狗"))
        let s = r.system
        let order = ["你有自己的情绪", "你是 Lumi", "温柔、话少", "小满", "恋人", "现在是线上", "猫猫比心"]
        let idx = order.map { s.range(of: $0)?.lowerBound }
        #expect(idx.allSatisfy { $0 != nil })
        #expect(zip(idx, idx.dropFirst()).allSatisfy { $0! < $1! })
        // 每轮会变的不进 system（缓存吃得住），在 context 里
        #expect(!s.contains("年糕") && !s.contains("狗狗") && !s.contains("现在是 20"))
        #expect(r.context.hasPrefix("现在是 20") && r.context.contains("年糕") && r.context.contains("狗狗"))
    }

    @Test func noStickerSectionWhenEmpty() {
        let s = Prompt.build(input(sampleContact())).system
        #expect(!s.contains("## 你的表情包"))
        #expect(!Prompt.build(input(sampleContact())).context.contains("## 你翻到的"))
    }

    @Test func altIdentityUsed() {
        var c = sampleContact()
        let alt = c.addAltIdentity(userName: "小雨", aboutMe: "刚搬来的邻居")
        let s = Prompt.build(input(c, identity: alt)).system
        #expect(s.contains("小雨") && s.contains("刚搬来的邻居") && s.contains("陌生人"))
    }

    @Test func offlineLine() {
        var c = sampleContact(); c.mode = .offline
        let s = Prompt.build(input(c)).system
        #expect(s.contains("现在是线下"))
        #expect(!s.contains("发消息"))                  // 线下不再带「像发消息那样说话」
    }

    @Test func trimsOldestKeepsLast() {
        let history = (0..<50).map { Message(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "字", count: 100) + "\($0)") }
        let r = Prompt.build(input(sampleContact(), history: history), budgetChars: 1000)
        let total = r.turns.reduce(0) { $0 + $1.text.count }
        #expect(total <= 1100)
        #expect(r.turns.last?.text.hasSuffix("49") == true)
        #expect(r.turns.first?.role == .user)
    }

    @Test func mergesConsecutiveSameRoleAndQuotes() {
        let a = Message(role: .assistant, text: "第一条"), b = Message(role: .assistant, text: "第二条")
        let u = Message(role: .user, text: "那我呢", quoteOf: a.id)
        let r = Prompt.build(input(sampleContact(), history: [Message(role: .user, text: "嗨"), a, b, u]))
        #expect(r.turns.map(\.role) == [.user, .assistant, .user])
        #expect(r.turns[1].text == "第一条\n\n第二条")
        #expect(r.turns[2].text.hasPrefix("（回复：第一条）"))
    }

    @Test func leadingAssistantGetsAStart() {
        let r = Prompt.build(input(sampleContact(), history: [Message(role: .assistant, text: "你来了。"), Message(role: .user, text: "嗯")]))
        #expect(r.turns.first?.role == .user)
        #expect(r.turns.count == 3)
    }

    @Test func imageOnLastUserTurn() {
        let r = Prompt.build(input(sampleContact(), history: [Message(role: .user, text: "看")], image: Data([1])))
        #expect(r.turns.last?.imageJPEG == Data([1]))
    }

    @Test func english() {
        let s = Prompt.build(input(sampleContact(), lang: .en)).system
        #expect(s.contains("You have your own feelings") && s.contains("You're online") && s.contains("You are Lumi"))
    }
}
