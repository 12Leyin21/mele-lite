import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct ChatFeedTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func thinkingOncePerTurnBeforeFirstBubble() {
        let msgs = [
            Message(id: "u1", role: .user, text: "在吗", at: at(0)),
            Message(id: "a1", role: .assistant, text: "在", thinking: "她来了", at: at(1)),
            Message(id: "a2", role: .assistant, text: "怎么啦", thinking: "她来了", at: at(2)),
        ]
        let items = ChatFeed.items(msgs, milestones: [], peeks: [], lang: .zh)
        #expect(items.map(\.kind) == [.text, .thinking, .text, .text])
        #expect(items[1].text == "她来了")
        #expect(items[1].id == "a1:t")
    }

    @Test func imageThenTextAndQuote() {
        let msgs = [
            Message(id: "a0", role: .assistant, text: "今天吃了什么", at: at(0)),
            Message(id: "u1", role: .user, text: "你看", quoteOf: "a0", imageFile: "x.jpg", at: at(1)),
        ]
        let items = ChatFeed.items(msgs, milestones: [], peeks: [], lang: .zh)
        #expect(items.map(\.kind) == [.text, .image("x.jpg"), .text])
        #expect(items[2].quote == "今天吃了什么")
        #expect(items[2].mine)
    }

    @Test func stickerTagTextIsNotABubble() {
        let msgs = [Message(id: "a1", role: .assistant, text: "[表情包：猫猫探头]", stickerID: "s9", at: at(0))]
        #expect(ChatFeed.items(msgs, milestones: [], peeks: [], lang: .zh).map(\.kind) == [.sticker("s9")])
    }

    @Test func stickerReplacesEmptyText() {
        let msgs = [Message(id: "a1", role: .assistant, text: "", stickerID: "s9", at: at(0))]
        #expect(ChatFeed.items(msgs, milestones: [], peeks: [], lang: .zh).map(\.kind) == [.sticker("s9")])
    }

    @Test func deedsAfterLastBubbleOfTurn() {
        let msgs = [
            Message(id: "u1", role: .user, text: "我们在一起一百天了", at: at(0)),
            Message(id: "a1", role: .assistant, text: "真的！", at: at(2)),
            Message(id: "u2", role: .user, text: "嗯", at: at(10)),
        ]
        let ms = [Milestone(contactID: "c", title: "一百天", at: at(1))]
        let pk = [PeekLog(contactID: "c", identityID: "i", rooms: [.chats, .lore], asked: "想看看", at: at(3))]
        let items = ChatFeed.items(msgs, milestones: ms, peeks: pk, lang: .zh)
        #expect(items.map(\.kind) == [.text, .text, .deeds(["立了里程碑：一百天", "翻了你的手机：聊天、世界书"]), .text])
        #expect(items[2].id == "deeds:u1")
    }

    @Test func refusedPeekEnglish() {
        let msgs = [Message(id: "a1", role: .assistant, text: "ok", at: at(1))]
        let pk = [PeekLog(contactID: "c", identityID: "i", rooms: [], asked: "", at: at(2))]
        let items = ChatFeed.items(msgs, milestones: [], peeks: pk, lang: .en)
        #expect(items.last?.kind == .deeds(["Asked to see your phone — you said no"]))
        #expect(items.last?.id == "deeds:start")
    }
}
