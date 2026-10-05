import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct PhoneCheckTests {
    struct World {
        let store: LiteStore
        let stickers: StickerLibrary
        var lumi: Contact
        var ava: Contact
        let alt: Identity
    }

    func world() throws -> World {
        let root = tempRoot()
        let store = LiteStore(root: root)
        let stickers = StickerLibrary(root: root)
        var lumi = sampleContact("Lumi")
        let alt = lumi.addAltIdentity(userName: "小雨", aboutMe: "")
        let ava = sampleContact("Ava")
        try store.save(lumi); try store.save(ava)
        try store.append(Message(role: .user, text: "跟 Lumi 说的悄悄话"), contact: lumi.id, identity: lumi.mainIdentity.id)
        try store.append(Message(role: .user, text: "小号跟 Lumi 说的"), contact: lumi.id, identity: alt.id)
        try store.append(Message(role: .user, text: "Ava 今天好看"), contact: ava.id, identity: ava.mainIdentity.id)
        try store.append(Message(role: .assistant, text: "谢谢夸奖"), contact: ava.id, identity: ava.mainIdentity.id)
        try store.saveLore([LoreEntry(title: "暗号", keys: ["日久方长"], content: "…")])
        let s = try stickers.add(solidPNG()); try stickers.setCaption(id: s.id, text: "猫猫比心")
        try store.addFavorite(Favorite(contactID: ava.id, identityID: ava.mainIdentity.id, messageIDs: [], text: "谢谢夸奖"))
        return World(store: store, stickers: stickers, lumi: lumi, ava: ava, alt: alt)
    }

    @Test func onlyGrantedRooms() throws {
        let w = try world()
        let snap = PhoneCheck.snapshot(store: w.store, stickers: w.stickers, viewer: w.lumi, viewerIdentity: w.lumi.mainIdentity, rooms: [.chats], lang: .zh)
        #expect(snap.contains("Ava 今天好看") && snap.contains("谢谢夸奖"))
        #expect(!snap.contains("暗号") && !snap.contains("猫猫比心"))
        let all = PhoneCheck.snapshot(store: w.store, stickers: w.stickers, viewer: w.lumi, viewerIdentity: w.lumi.mainIdentity, rooms: Set(PeekRoom.allCases), lang: .zh)
        #expect(all.contains("暗号") && all.contains("猫猫比心") && all.contains("谢谢夸奖"))
    }

    @Test func neverItsOwnChatOrAlt() throws {
        let w = try world()
        let snap = PhoneCheck.snapshot(store: w.store, stickers: w.stickers, viewer: w.lumi, viewerIdentity: w.lumi.mainIdentity, rooms: Set(PeekRoom.allCases), lang: .zh)
        #expect(!snap.contains("跟 Lumi 说的悄悄话") && !snap.contains("小号跟 Lumi 说的"))
    }

    @Test func altViewerSeesNoChats() throws {
        let w = try world()
        let snap = PhoneCheck.snapshot(store: w.store, stickers: w.stickers, viewer: w.lumi, viewerIdentity: w.alt, rooms: [.chats], lang: .zh)
        #expect(!snap.contains("Ava 今天好看"))
    }

    @Test func otherContactsAltChatsHidden() throws {
        var w = try world()
        let avaAlt = w.ava.addAltIdentity(userName: "阿雾", aboutMe: "")
        try w.store.save(w.ava)
        try w.store.append(Message(role: .user, text: "Ava 小号的秘密"), contact: w.ava.id, identity: avaAlt.id)
        let snap = PhoneCheck.snapshot(store: w.store, stickers: w.stickers, viewer: w.lumi, viewerIdentity: w.lumi.mainIdentity, rooms: [.chats], lang: .zh)
        #expect(!snap.contains("Ava 小号的秘密"))
    }

    @Test func logKept() throws {
        let w = try world()
        try w.store.appendPeek(PeekLog(contactID: w.lumi.id, identityID: w.lumi.mainIdentity.id, rooms: [.chats], asked: "你最近跟谁聊天"))
        #expect(w.store.peeks().map(\.asked) == ["你最近跟谁聊天"])
    }
}
