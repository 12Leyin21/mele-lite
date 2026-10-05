import Foundation

/// 手机上的存储：一个目录下几份 JSON。聊天按「联系人 / 身份」各一个 jsonl，追加写。
///
/// root/
///   contacts.json
///   favorites.json
///   chats/<contact>/<identity>.jsonl
public final class LiteStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: 通用

    func readList<T: Decodable>(_ name: String) -> [T] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return [] }
        return (try? Self.decoder.decode([T].self, from: data)) ?? []
    }

    func writeList<T: Encodable>(_ list: [T], _ name: String) throws {
        let data = try Self.encoder.encode(list)
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    // MARK: 联系人

    public func contacts() -> [Contact] { lock.withLock { readList("contacts.json") } }

    public func save(_ c: Contact) throws {
        try lock.withLock {
            var all: [Contact] = readList("contacts.json")
            if let i = all.firstIndex(where: { $0.id == c.id }) { all[i] = c } else { all.append(c) }
            try writeList(all, "contacts.json")
        }
    }

    public func delete(contact id: String) throws {
        try lock.withLock {
            let all: [Contact] = readList("contacts.json")
            try writeList(all.filter { $0.id != id }, "contacts.json")
            try? fm.removeItem(at: chatsDir(contact: id))
        }
    }

    // MARK: 聊天

    func chatsDir(contact: String) -> URL { root.appendingPathComponent("chats").appendingPathComponent(contact) }

    public func messagesFile(contact: String, identity: String) -> URL {
        chatsDir(contact: contact).appendingPathComponent("\(identity).jsonl")
    }

    public func append(_ m: Message, contact: String, identity: String) throws {
        try lock.withLock {
            let file = messagesFile(contact: contact, identity: identity)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var line = try Self.encoder.encode(m)
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(line)
            } else {
                try line.write(to: file)
            }
        }
    }

    public func messages(contact: String, identity: String) -> [Message] {
        lock.withLock {
            guard let data = try? Data(contentsOf: messagesFile(contact: contact, identity: identity)) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Message.self, from: Data($0)) }
        }
    }

    // MARK: 收藏

    public func favorites() -> [Favorite] { lock.withLock { readList("favorites.json") } }

    public func addFavorite(_ f: Favorite) throws {
        try lock.withLock {
            var all: [Favorite] = readList("favorites.json")
            all.append(f)
            try writeList(all, "favorites.json")
        }
    }

    public func removeFavorite(id: String) throws {
        try lock.withLock {
            let all: [Favorite] = readList("favorites.json")
            try writeList(all.filter { $0.id != id }, "favorites.json")
        }
    }

    // MARK: 世界书

    public func lore() -> [LoreEntry] { lock.withLock { readList("lore.json") } }

    public func saveLore(_ entries: [LoreEntry]) throws { try lock.withLock { try writeList(entries, "lore.json") } }

    // MARK: 查手机记录

    public func peeks() -> [PeekLog] { lock.withLock { readList("peeks.json") } }

    public func appendPeek(_ p: PeekLog) throws {
        try lock.withLock {
            var all: [PeekLog] = readList("peeks.json")
            all.append(p)
            try writeList(all, "peeks.json")
        }
    }

    // MARK: 里程碑

    public func milestones() -> [Milestone] { lock.withLock { readList("milestones.json") } }

    public func appendMilestone(_ m: Milestone) throws {
        try lock.withLock {
            var all: [Milestone] = readList("milestones.json")
            all.append(m)
            try writeList(all, "milestones.json")
        }
    }

    // MARK: TA 发的照片

    public func saveImage(_ data: Data) throws -> String {
        let dir = root.appendingPathComponent("images")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func imageURL(_ name: String) -> URL { root.appendingPathComponent("images").appendingPathComponent(name) }

    // MARK: 信

    public func letters() -> [Letter] { lock.withLock { readList("letters.json") } }

    public func saveLetter(_ l: Letter) throws {
        try lock.withLock {
            var all: [Letter] = readList("letters.json")
            if let i = all.firstIndex(where: { $0.id == l.id }) { all[i] = l } else { all.append(l) }
            try writeList(all, "letters.json")
        }
    }
}
