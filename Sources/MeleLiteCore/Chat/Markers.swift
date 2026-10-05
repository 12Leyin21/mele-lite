import Foundation

/// 它在回复里写的小标记（提示词里教的写法），解出来以后从正文里拿掉：
/// - 发表情包：`[表情包：描述]` / `[sticker: …]`
/// - 立里程碑：`⟪里程碑：标题⟫` / `⟪milestone: …⟫`
/// - 想查手机：`⟪想查手机：想看什么⟫` / `⟪peek: …⟫`
public struct ParsedReply: Equatable, Sendable {
    public var text: String
    public var stickers: [String]
    public var milestones: [String]
    public var wantsPeek: String?
}

public enum Markers {
    static let sticker = try! NSRegularExpression(pattern: #"\[(?:表情包|sticker)\s*[:：]\s*([^\]\n]+?)\s*\]"#, options: .caseInsensitive)
    static let milestone = try! NSRegularExpression(pattern: #"⟪(?:里程碑|milestone)\s*[:：]\s*([^⟫\n]+?)\s*⟫"#, options: .caseInsensitive)
    static let peek = try! NSRegularExpression(pattern: #"⟪(?:想查手机|peek)\s*[:：]\s*([^⟫\n]+?)\s*⟫"#, options: .caseInsensitive)

    public static func parse(_ reply: String) -> ParsedReply {
        var text = reply
        let stickers = pull(sticker, from: &text)
        let milestones = pull(milestone, from: &text)
        let peeks = pull(peek, from: &text)
        return ParsedReply(text: tidy(text), stickers: stickers, milestones: milestones, wantsPeek: peeks.first)
    }

    static func pull(_ re: NSRegularExpression, from text: inout String) -> [String] {
        let ns = text as NSString
        let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let found = ms.map { ns.substring(with: $0.range(at: 1)) }
        text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return found
    }

    /// 拿掉标记后：每行去掉行尾空格，连着的空段并成一个空行，首尾空白去掉。
    static func tidy(_ s: String) -> String {
        let paras = s.split(separator: try! Regex(#"\n\s*\n"#))
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n") }
            .filter { !$0.isEmpty }
        return paras.joined(separator: "\n\n")
    }
}
