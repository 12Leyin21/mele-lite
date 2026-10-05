import Foundation

/// 导出 / 导入：一个 JSON 文件装下所有东西（图转 base64），**不含 key**。只能导进空库，不合并。
public struct ExportBundle: Codable, Sendable {
    public var version: Int
    public var contacts: [Contact]
    public var chats: [String: [String: [Message]]]     // 联系人 → 身份 → 消息
    public var lore: [LoreEntry]
    public var favorites: [Favorite]
    public var milestones: [Milestone]
    public var letters: [Letter]
    public var peeks: [PeekLog]
    public var stickers: [Sticker]
    public var files: [String: Data]                   // "stickers/<file>" / "images/<file>" → 原图
}

public struct ImportError: Error, Equatable { public let message: String }

extension LiteStore {
    public static let exportVersion = 1

    public func export(stickers lib: StickerLibrary) throws -> Data {
        let cs = contacts()
        var chats: [String: [String: [Message]]] = [:]
        var files: [String: Data] = [:]
        for c in cs {
            for i in c.identities {
                let ms = messages(contact: c.id, identity: i.id)
                chats[c.id, default: [:]][i.id] = ms
                for m in ms { if let f = m.imageFile, let d = try? Data(contentsOf: imageURL(f)) { files["images/" + f] = d } }
            }
        }
        let ss = lib.all()
        for s in ss { if let d = try? Data(contentsOf: lib.imageURL(s)) { files["stickers/" + s.file] = d } }
        let b = ExportBundle(version: Self.exportVersion, contacts: cs, chats: chats, lore: lore(), favorites: favorites(),
                             milestones: milestones(), letters: letters(), peeks: peeks(), stickers: ss, files: files)
        return try Self.encoder.encode(b)
    }

    public func importAll(_ data: Data, stickers lib: StickerLibrary) throws {
        guard let b = try? Self.decoder.decode(ExportBundle.self, from: data) else { throw ImportError(message: "读不出这个文件") }
        guard b.version == Self.exportVersion else { throw ImportError(message: "这个文件的版本认不出（\(b.version)）") }
        guard contacts().isEmpty else { throw ImportError(message: "只能导进一个空的 Mele Lite") }
        for c in b.contacts { try save(c) }
        for (cid, byIdentity) in b.chats { for (iid, ms) in byIdentity { for m in ms { try append(m, contact: cid, identity: iid) } } }
        try saveLore(b.lore)
        try writeList(b.favorites, "favorites.json")
        try writeList(b.milestones, "milestones.json")
        try writeList(b.letters, "letters.json")
        try writeList(b.peeks, "peeks.json")
        for (path, d) in b.files where path.hasPrefix("images/") {
            let dir = root.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try d.write(to: dir.appendingPathComponent(String(path.dropFirst("images/".count))))
        }
        for s in b.stickers { if let d = b.files["stickers/" + s.file] { try d.write(to: lib.imageURL(s)) } }
        try lib.replaceIndex(b.stickers)
    }
}

extension StickerLibrary {
    func replaceIndex(_ list: [Sticker]) throws { try write(list) }
}
