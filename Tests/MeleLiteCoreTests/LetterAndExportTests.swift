import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct LetterDeskTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func shouldWrite() {
        #expect(!LetterDesk.shouldWrite(lastLetter: nil, lastChat: nil, now: t0))
        #expect(LetterDesk.shouldWrite(lastLetter: nil, lastChat: t0, now: t0))
        let letter = t0, chat = t0.addingTimeInterval(3600)
        #expect(!LetterDesk.shouldWrite(lastLetter: letter, lastChat: chat, now: t0.addingTimeInterval(10 * 3600)))
        #expect(LetterDesk.shouldWrite(lastLetter: letter, lastChat: chat, now: t0.addingTimeInterval(21 * 3600)))
        #expect(!LetterDesk.shouldWrite(lastLetter: letter, lastChat: t0.addingTimeInterval(-60), now: t0.addingTimeInterval(30 * 3600)))
    }

    @Test func writesAndStores() async throws {
        let store = LiteStore(root: tempRoot())
        let c = sampleContact()
        try store.save(c)
        try store.append(Message(role: .user, text: "今天好累"), contact: c.id, identity: c.mainIdentity.id)
        let fake = FakeClient(reply: "# 累了就靠一下\n今天你说好累。\n\n—— Lumi")
        let l = try await LetterDesk.write(contact: c, identity: c.mainIdentity, store: store, client: fake, lang: .zh, now: t0)
        #expect(l.title == "累了就靠一下")
        #expect(l.body.hasPrefix("今天你说好累。") && l.body.hasSuffix("—— Lumi"))
        #expect(store.letters().count == 1)
        #expect(fake.requests.first?.turns.last?.text.contains("对方刚打开手机") == true)
        #expect(store.messages(contact: c.id, identity: c.mainIdentity.id).count == 1)
    }
}

@Suite struct ExportTests {
    @Test func roundTrip() async throws {
        let rootA = tempRoot()
        let a = LiteStore(root: rootA), libA = StickerLibrary(root: rootA)
        var c = sampleContact()
        let alt = c.addAltIdentity(userName: "小雨", aboutMe: "")
        try a.save(c)
        let img = try a.saveImage(solidPNG())
        try a.append(Message(role: .user, text: "主号", imageFile: img), contact: c.id, identity: c.mainIdentity.id)
        try a.append(Message(role: .user, text: "小号"), contact: c.id, identity: alt.id)
        try a.saveLore([LoreEntry(title: "暗号", keys: ["日久方长"], content: "…")])
        try a.addFavorite(Favorite(contactID: c.id, identityID: c.mainIdentity.id, messageIDs: [], text: "收藏"))
        try a.appendMilestone(Milestone(contactID: c.id, title: "一百天"))
        try a.saveLetter(Letter(contactID: c.id, identityID: c.mainIdentity.id, title: "信", body: "正文"))
        let s = try libA.add(solidPNG(0.2)); try libA.setCaption(id: s.id, text: "猫猫")
        let vault = MemoryVault(); vault.set("sk-secret-should-not-leak", for: "anthropic")

        let data = try a.export(stickers: libA)
        #expect(String(decoding: data, as: UTF8.self).contains("sk-secret") == false)

        let rootB = tempRoot()
        let b = LiteStore(root: rootB), libB = StickerLibrary(root: rootB)
        try b.importAll(data, stickers: libB)
        #expect(b.contacts() == a.contacts())
        #expect(b.messages(contact: c.id, identity: c.mainIdentity.id) == a.messages(contact: c.id, identity: c.mainIdentity.id))
        #expect(b.messages(contact: c.id, identity: alt.id).map(\.text) == ["小号"])
        #expect(b.lore() == a.lore() && b.favorites() == a.favorites() && b.milestones() == a.milestones() && b.letters() == a.letters())
        #expect(libB.all().map(\.caption) == ["猫猫"])
        #expect(FileManager.default.fileExists(atPath: libB.imageURL(libB.all()[0]).path))
        #expect(FileManager.default.fileExists(atPath: b.imageURL(img).path))
    }

    @Test func refusesNonEmptyAndUnknownVersion() throws {
        let a = LiteStore(root: tempRoot()), lib = StickerLibrary(root: tempRoot())
        try a.save(sampleContact())
        let data = try a.export(stickers: lib)
        #expect(throws: ImportError.self) { try a.importAll(data, stickers: lib) }
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["version"] = 99
        let bad = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ImportError.self) { try LiteStore(root: tempRoot()).importAll(bad, stickers: lib) }
    }
}

@Suite struct LetterParseTests {
    @Test func titleThenBody() {
        let p = LetterDesk.parse("# 《下雨天》\n今天想起你说的那家书店。\n\n还想去。", lang: .zh)
        #expect(p.title == "下雨天")
        #expect(p.body == "今天想起你说的那家书店。\n\n还想去。")
    }

    @Test func emptyTitleFallsBack() {
        #expect(LetterDesk.parse("\n", lang: .en).title == "A letter for you")
    }
}
