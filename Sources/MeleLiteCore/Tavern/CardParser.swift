import Compression
import Foundation

/// 导入酒馆角色卡。按公开规范读（Character Card V2 / V3），解析自己写；照 Mele 服务器 brain/tavern.py 的规则改写。
/// PNG：文字块里 `ccv3` 优先、`chara` 其次，值是 base64 JSON；图本身当头像。JSON 直接读。卡里的东西只当数据。
public struct ParsedCard: Sendable {
    public var name: String
    public var persona: String
    public var greetings: [String]
    public var avatarPNG: Data?
    public var lore: [LoreEntry]
    public var creatorNotes: String
    public var skippedLore: Int
}

public struct CardError: Error, Equatable {
    public let message: String
}

public enum CardParser {
    static let maxBytes = 10 * 1024 * 1024
    static let maxText = 30_000
    static let textFields = ["name", "nickname", "description", "personality", "scenario", "first_mes", "mes_example",
                             "system_prompt", "post_history_instructions", "creator_notes"]
    static let pngSig = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    public static func parse(_ data: Data, userName: String, lang: Lang) throws -> ParsedCard {
        let zh = lang == .zh
        guard data.count <= maxBytes else { throw CardError(message: zh ? "文件太大了（最多 10MB）" : "File too large (10MB max)") }
        let obj: [String: Any]
        var image: Data?
        if data.starts(with: pngSig) {
            let texts = pngTexts(data)
            guard let raw = texts["ccv3"] ?? texts["chara"] else {
                throw CardError(message: zh ? "这张图里没有角色卡的数据" : "This image has no character card data")
            }
            guard let d = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw CardError(message: zh ? "卡里的数据读不出来" : "Couldn't read the card data")
            }
            obj = o; image = data
        } else {
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CardError(message: zh ? "只认 PNG 角色卡或 JSON 角色卡" : "Only PNG or JSON character cards are supported")
            }
            obj = o
        }
        let d = (obj["data"] as? [String: Any]) ?? obj
        let name = String((s(d["nickname"]).isEmpty ? s(d["name"]) : s(d["nickname"])).prefix(20))
        guard !name.isEmpty else { throw CardError(message: zh ? "这张卡没有名字，读不出来" : "This card has no name") }
        guard textFields.reduce(0, { $0 + s(d[$1]).count }) <= maxText else {
            throw CardError(message: zh ? "这张卡的文字太长了（超过 \(maxText) 字）" : "This card's text is too long")
        }
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        let f = { (t: String) in fill(t, char: name, user: user) }
        let first = s(d["first_mes"])
        let alts = (d["alternate_greetings"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let greetings = (first.isEmpty ? [] : [first]) + alts
        let entries = ((d["character_book"] as? [String: Any])?["entries"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let (lore, skipped) = loreEntries(entries, name: name, user: user)
        return ParsedCard(name: name, persona: persona(d, f: f, zh: zh), greetings: greetings.map(f), avatarPNG: image,
                          lore: lore, creatorNotes: String(s(d["creator_notes"]).prefix(2000)), skippedLore: skipped)
    }

    static func s(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    /// {{char}} → 角色名，{{user}} → TA 的名字；{{original}} 拿掉（那是酒馆自己的系统提示词）。
    static func fill(_ text: String, char: String, user: String) -> String {
        var t = text.replacingOccurrences(of: #"\{\{\s*original\s*\}\}"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\{\{\s*char\s*\}\}|<BOT>|<CHAR>"#, with: char, options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\{\{\s*user\s*\}\}|<USER>"#, with: user, options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func persona(_ d: [String: Any], f: (String) -> String, zh: Bool) -> String {
        let h = zh ? ["## 角色", "性格：", "## 场景", "## 说话示例", "## 作者对这个角色的说明"]
                   : ["## Character", "Personality: ", "## Scenario", "## How they talk (examples)", "## The author's notes on this character"]
        var parts: [String] = []
        let body = [f(s(d["description"])), s(d["personality"]).isEmpty ? "" : h[1] + f(s(d["personality"]))].filter { !$0.isEmpty }
        if !body.isEmpty { parts.append(h[0] + "\n" + body.joined(separator: "\n")) }
        if !s(d["scenario"]).isEmpty { parts.append(h[2] + "\n" + f(s(d["scenario"]))) }
        let example = f(s(d["mes_example"]).replacingOccurrences(of: "<START>", with: "", options: .caseInsensitive))
        if !example.isEmpty { parts.append(h[3] + "\n" + example) }
        let author = f(s(d["system_prompt"]))
        if !author.isEmpty { parts.append(h[4] + "\n" + author) }
        return parts.joined(separator: "\n\n")
    }

    /// 单个汉字可以当关键词，单个字母不行。
    static func keywordOK(_ k: String) -> Bool {
        if k.count >= 2 { return true }
        guard let u = k.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(Int(u.value)) || (0x3400...0x4DBF).contains(Int(u.value))
    }

    static func loreEntries(_ entries: [[String: Any]], name: String, user: String) -> ([LoreEntry], Int) {
        var out: [LoreEntry] = []
        var skipped = 0
        for e in entries {
            let raw = ((e["keys"] as? [Any] ?? []) + (e["secondary_keys"] as? [Any] ?? [])).compactMap { $0 as? String }
            var seen = Set<String>(), kws: [String] = []
            for k in raw {
                let k2 = fill(k, char: name, user: user).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if keywordOK(k2) && seen.insert(k2.lowercased()).inserted { kws.append(String(k2.prefix(40))) }
            }
            let content = String(fill(s(e["content"]), char: name, user: user).prefix(2000))
            let constant = (e["constant"] as? Bool) == true
            if content.isEmpty || (kws.isEmpty && !constant) { skipped += 1; continue }
            let title = [s(e["comment"]), s(e["name"]), kws.first ?? name].first { !$0.isEmpty } ?? name
            out.append(LoreEntry(title: String(title.prefix(40)), keys: kws.isEmpty ? [name] : Array(kws.prefix(20)), content: content,
                                 constant: constant, enabled: (e["enabled"] as? Bool) != false))
        }
        return (out, skipped)
    }

    /// PNG 的 tEXt / zTXt / iTXt 文字块 → [关键字: 文字]
    static func pngTexts(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        let b = [UInt8](data)
        var i = 8
        while i + 8 <= b.count {
            let n = Int(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
            let kind = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            let start = i + 8, end = min(start + n, b.count)
            let body = Array(b[start..<end])
            i = start + n + 4
            if kind == "IEND" { break }
            guard let z = body.firstIndex(of: 0) else { continue }
            let key = String(bytes: body[..<z], encoding: .isoLatin1) ?? ""
            let rest = Array(body[(z + 1)...])
            switch kind {
            case "tEXt":
                out[key] = String(bytes: rest, encoding: .isoLatin1)
            case "zTXt":
                if rest.count > 1, let d = inflate(Array(rest[1...])) { out[key] = String(bytes: d, encoding: .isoLatin1) }
            case "iTXt":
                guard rest.count > 2 else { continue }
                let compressed = rest[0] == 1
                var r = Array(rest[2...])
                guard let l = r.firstIndex(of: 0) else { continue }; r = Array(r[(l + 1)...])
                guard let t = r.firstIndex(of: 0) else { continue }; r = Array(r[(t + 1)...])
                let bytes = compressed ? inflate(r) : r
                if let bytes { out[key] = String(bytes: bytes, encoding: .utf8) }
            default: break
            }
        }
        return out
    }

    /// zlib 流（去掉 2 字节头）用系统自带的 Compression 解开。
    static func inflate(_ z: [UInt8]) -> [UInt8]? {
        guard z.count > 2 else { return nil }
        let src = Array(z[2...])
        var cap = max(src.count * 8, 4096)
        while cap <= 64 * 1024 * 1024 {
            var dst = [UInt8](repeating: 0, count: cap)
            let n = compression_decode_buffer(&dst, cap, src, src.count, nil, COMPRESSION_ZLIB)
            if n > 0 && n < cap { return Array(dst[..<n]) }
            cap *= 4
        }
        return nil
    }
}
