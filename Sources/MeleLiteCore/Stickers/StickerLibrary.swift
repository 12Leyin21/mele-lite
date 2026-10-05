import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 表情包库：root/stickers/<sha>.png + stickers.json。同一张图只存一次、只看一次。
public final class StickerLibrary: @unchecked Sendable {
    public struct Full: Error {}

    let root: URL
    let limit: Int
    private let lock = NSLock()

    public init(root: URL, limit: Int = 300) {
        self.root = root.appendingPathComponent("stickers")
        self.limit = limit
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    var indexFile: URL { root.appendingPathComponent("stickers.json") }

    public func all() -> [Sticker] {
        lock.withLock {
            guard let d = try? Data(contentsOf: indexFile) else { return [] }
            return (try? LiteStore.decoder.decode([Sticker].self, from: d)) ?? []
        }
    }

    func write(_ list: [Sticker]) throws {
        try LiteStore.encoder.encode(list).write(to: indexFile, options: .atomic)
    }

    public func imageURL(_ s: Sticker) -> URL { root.appendingPathComponent(s.file) }

    @discardableResult
    public func add(_ image: Data) throws -> Sticker {
        let sha = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        var list = all()
        if let same = list.first(where: { $0.sha == sha }) { return same }
        guard list.count < limit else { throw Full() }
        let s = Sticker(sha: sha, file: "\(sha).png")
        try image.write(to: imageURL(s), options: .atomic)
        list.append(s)
        try lock.withLock { try write(list) }
        return s
    }

    /// 让模型看一眼写描述（用用户自己的 key）。看过的不再看。
    public func caption(_ s: Sticker, using client: LLMClient, lang: Lang) async throws -> Sticker {
        if s.captionedAt != nil, !s.caption.isEmpty { return s }
        let ask = lang == .zh
            ? "这是一张聊天用的表情包。用一句话（20 字以内）说它是什么、表达什么情绪，只写这一句。"
            : "This is a chat sticker. In one short line (under 12 words), say what it shows and the feeling it expresses. Write only that line."
        let jpeg = Self.jpeg(try Data(contentsOf: imageURL(s))) ?? Data()
        var text = ""
        for try await e in client.stream(ChatRequest(system: "", turns: [ChatTurn(role: .user, text: ask, imageJPEG: jpeg)], maxTokens: 200)) {
            if case .text(let t) = e { text += t }
        }
        var done = s
        done.caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        done.captionedAt = Date()
        try update(done)
        return done
    }

    public func setCaption(id: String, text: String) throws {
        guard var s = all().first(where: { $0.id == id }) else { return }
        s.caption = text
        s.captionedAt = s.captionedAt ?? Date()
        try update(s)
    }

    func update(_ s: Sticker) throws {
        var list = all()
        if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s }
        try lock.withLock { try write(list) }
    }

    public func remove(id: String) throws {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: imageURL(list[i]))
        list.remove(at: i)
        try lock.withLock { try write(list) }
    }

    /// 它写的描述 → 库里最像的一张：完全一样 > 互相包含（取重合最长的）；都不沾边就 nil。
    public func match(_ wanted: String) -> Sticker? {
        let w = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty else { return nil }
        let list = all().filter { !$0.caption.isEmpty }
        if let exact = list.first(where: { $0.caption.lowercased() == w }) { return exact }
        return list
            .filter { $0.caption.lowercased().contains(w) || w.contains($0.caption.lowercased()) }
            .max { min($0.caption.count, w.count) < min($1.caption.count, w.count) }
    }

    /// 给模型看的图统一转 JPEG、长边 ≤ 768
    static func jpeg(_ data: Data, maxSide: Int = 768) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
