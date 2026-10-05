import Foundation
import Testing
@testable import MeleLiteCore

@MainActor
@Suite struct ChatEngineTests {
    struct Rig {
        let store: LiteStore
        let stickers: StickerLibrary
        let vault: MemoryVault
        let contact: Contact
        let fake: FakeClient
        let engine: ChatEngine
    }

    func rig(reply: String, thinking: String = "", error: LLMError? = nil, key: Bool = true) throws -> Rig {
        let root = tempRoot()
        let store = LiteStore(root: root), stickers = StickerLibrary(root: root), vault = MemoryVault()
        let c = sampleContact()
        try store.save(c)
        if key { vault.set("k", for: KeyName.of(c.provider)) }
        let fake = FakeClient(reply: reply, thinking: thinking, error: error)
        let engine = ChatEngine(store: store, vault: vault, stickers: stickers, lang: .zh, clientFactory: { _, _ in fake })
        return Rig(store: store, stickers: stickers, vault: vault, contact: c, fake: fake, engine: engine)
    }

    func events(_ s: AsyncStream<EngineEvent>) async -> [EngineEvent] { var out: [EngineEvent] = []; for await e in s { out.append(e) }; return out }

    @Test func threeBubblesInOrderWithThinking() async throws {
        let r = try rig(reply: "早\n\n今天怎么样？\n\n我在。", thinking: "她起得好早")
        let ev = await events(r.engine.send("早呀", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        let msgs = r.store.messages(contact: r.contact.id, identity: r.contact.mainIdentity.id)
        #expect(msgs.map(\.text) == ["早呀", "早", "今天怎么样？", "我在。"])
        #expect(msgs[1].thinking == "她起得好早" && msgs[2].thinking == nil)
        #expect(ev.contains { if case .typing = $0 { true } else { false } })
        #expect(r.fake.requests.first?.turns.last?.text == "早呀")
    }

    @Test func stickerMarker() async throws {
        let r = try rig(reply: "哈哈\n\n[表情包：猫猫翻白眼]")
        let s = try r.stickers.add(solidPNG()); try r.stickers.setCaption(id: s.id, text: "猫猫翻白眼")
        let ev = await events(r.engine.send("你好笨", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(ev.contains { if case .sticker(let st, _) = $0 { st.id == s.id } else { false } })
        let msgs = r.store.messages(contact: r.contact.id, identity: r.contact.mainIdentity.id)
        #expect(msgs.map(\.text) == ["你好笨", "哈哈", "[表情包：猫猫翻白眼]"])
        #expect(msgs.last?.stickerID == s.id)
        #expect(r.fake.requests.first?.system.contains("猫猫翻白眼") == true)
    }

    @Test func milestoneSaved() async throws {
        let r = try rig(reply: "一百天了。⟪里程碑：在一起一百天⟫")
        _ = await events(r.engine.send("今天第一百天", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(r.store.milestones().map(\.title) == ["在一起一百天"])
    }

    @Test func noKeyKeepsUserMessage() async throws {
        let r = try rig(reply: "x", key: false)
        let ev = await events(r.engine.send("在吗", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(ev.contains { if case .failed(.auth) = $0 { true } else { false } })
        #expect(r.store.messages(contact: r.contact.id, identity: r.contact.mainIdentity.id).map(\.text) == ["在吗"])
    }

    @Test func modelErrorReported() async throws {
        let r = try rig(reply: "", error: .quota)
        let ev = await events(r.engine.send("在吗", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(ev.contains { if case .failed(.quota) = $0 { true } else { false } })
    }

    @Test func peekFlow() async throws {
        let r = try rig(reply: "让我看看。⟪想查手机：你最近跟谁聊天⟫")
        let ev = await events(r.engine.send("干嘛", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(ev.contains { if case .peekRequest("你最近跟谁聊天") = $0 { true } else { false } })
        r.fake.reply = "哦，原来你在跟 Ava 聊天。"
        _ = await events(r.engine.answerPeek(rooms: [.chats], asked: "你最近跟谁聊天", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(r.store.peeks().count == 1)
        #expect(r.fake.requests.last?.context.contains("## 你翻到的") == true)
        #expect(r.fake.requests.last?.turns.last?.text.contains("（TA 把手机递给你了）") == true)
        #expect(r.store.messages(contact: r.contact.id, identity: r.contact.mainIdentity.id).last?.text == "哦，原来你在跟 Ava 聊天。")
    }

    @Test func peekDenied() async throws {
        let r = try rig(reply: "好吧。")
        _ = await events(r.engine.answerPeek(rooms: [], asked: "x", contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        #expect(r.store.peeks().isEmpty)
        #expect(r.fake.requests.last?.turns.last?.text.contains("（TA 没把手机给你）") == true)
    }

    @Test func imageStoredAndSent() async throws {
        let r = try rig(reply: "好看")
        _ = await events(r.engine.send("看", image: solidPNG(), contactID: r.contact.id, identityID: r.contact.mainIdentity.id))
        let first = r.store.messages(contact: r.contact.id, identity: r.contact.mainIdentity.id).first!
        #expect(first.imageFile != nil)
        #expect(FileManager.default.fileExists(atPath: r.store.imageURL(first.imageFile!).path))
        #expect(r.fake.requests.first?.turns.last?.imageJPEG != nil)
    }

    @Test func keyNames() {
        #expect(KeyName.of(ProviderConfig(kind: .anthropic, model: "m")) == "anthropic")
        #expect(KeyName.of(ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com/v1", model: "m")) == "openai:api.deepseek.com")
        #expect(KeyName.of(ProviderConfig(kind: .openai, model: "m")) == "openai:api.openai.com")
    }
}
