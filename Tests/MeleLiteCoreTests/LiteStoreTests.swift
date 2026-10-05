import Foundation
import Testing
@testable import MeleLiteCore

func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("melelite-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func sampleContact(_ name: String = "Lumi") -> Contact {
    Contact(name: name, persona: "温柔、话少", provider: ProviderConfig(kind: .openai, baseURL: nil, model: "deepseek-chat", thinking: false))
}

@Suite struct LiteStoreTests {
    @Test func contactRoundTrip() throws {
        let store = LiteStore(root: tempRoot())
        let c = sampleContact()
        try store.save(c)
        let back = store.contacts()
        #expect(back.count == 1)
        #expect(back[0] == c)
        #expect(back[0].mainIdentity.isMain)
    }

    @Test func identitiesKeepSeparateMessages() throws {
        let store = LiteStore(root: tempRoot())
        var c = sampleContact()
        let alt = c.addAltIdentity(userName: "小雨", aboutMe: "")
        try store.save(c)
        try store.append(Message(role: .user, text: "主号的话"), contact: c.id, identity: c.mainIdentity.id)
        try store.append(Message(role: .user, text: "小号的话"), contact: c.id, identity: alt.id)
        #expect(store.messages(contact: c.id, identity: c.mainIdentity.id).map(\.text) == ["主号的话"])
        #expect(store.messages(contact: c.id, identity: alt.id).map(\.text) == ["小号的话"])
        #expect(alt.relationship == "陌生人")
    }

    @Test func manyMessagesKeepOrder() throws {
        let store = LiteStore(root: tempRoot())
        let c = sampleContact()
        try store.save(c)
        for i in 0..<1000 { try store.append(Message(role: .user, text: "\(i)"), contact: c.id, identity: c.mainIdentity.id) }
        let texts = store.messages(contact: c.id, identity: c.mainIdentity.id).map(\.text)
        #expect(texts.count == 1000)
        #expect(texts.first == "0" && texts.last == "999")
    }

    @Test func deleteContactRemovesMessages() throws {
        let root = tempRoot()
        let store = LiteStore(root: root)
        let c = sampleContact()
        try store.save(c)
        try store.append(Message(role: .user, text: "hi"), contact: c.id, identity: c.mainIdentity.id)
        try store.delete(contact: c.id)
        #expect(store.contacts().isEmpty)
        #expect(store.messages(contact: c.id, identity: c.mainIdentity.id).isEmpty)
    }

    @Test func badLinesAreSkipped() throws {
        let root = tempRoot()
        let store = LiteStore(root: root)
        let c = sampleContact()
        try store.save(c)
        try store.append(Message(role: .user, text: "好的那行"), contact: c.id, identity: c.mainIdentity.id)
        let file = store.messagesFile(contact: c.id, identity: c.mainIdentity.id)
        let h = try FileHandle(forWritingTo: file)
        h.seekToEndOfFile(); h.write("{坏掉的行\n".data(using: .utf8)!); try h.close()
        #expect(store.messages(contact: c.id, identity: c.mainIdentity.id).map(\.text) == ["好的那行"])
    }

    @Test func favoritesOutliveMessages() throws {
        let store = LiteStore(root: tempRoot())
        let c = sampleContact()
        try store.save(c)
        let m1 = Message(role: .assistant, text: "第一句"), m2 = Message(role: .assistant, text: "第二句")
        try store.append(m1, contact: c.id, identity: c.mainIdentity.id)
        try store.append(m2, contact: c.id, identity: c.mainIdentity.id)
        let fav = Favorite(contactID: c.id, identityID: c.mainIdentity.id, messageIDs: [m1.id, m2.id], text: "第一句\n第二句")
        try store.addFavorite(fav)
        try store.delete(contact: c.id)
        #expect(store.favorites().map(\.text) == ["第一句\n第二句"])
        try store.removeFavorite(id: fav.id)
        #expect(store.favorites().isEmpty)
    }
}
