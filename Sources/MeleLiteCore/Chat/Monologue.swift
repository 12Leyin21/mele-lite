import Foundation

/// 手写独白（10-04 Tilia：Lite 也要，做成能选的）。思路照 Mele 服务器那版：
/// 模型自己的思考管不住，就让 TA 把心里过的东西写在回复最前面，用 [独白]…[/独白] 包着；
/// 发出去之前切下来，当思考给用户看，剩下的才是正文。历史里只存正文。
public enum Monologue {
    /// 收尾标记模型常写走样（[独白 完] [独白结束] [end monologue]……），所以不看收尾长什么样：
    /// 第一个标记是开头，紧跟着的下一个标记就是收尾。
    static let tag = try! NSRegularExpression(
        pattern: #"\[\s*(?:/|end\s+)?\s*(?:独白|monologue)\s*(?:/|完|结束|end)?\s*\]"#, options: [.caseInsensitive])
    static let saysYou = try! NSRegularExpression(pattern: #"你|\byou\b"#, options: [.caseInsensitive])
    static let quoted = try! NSRegularExpression(pattern: #"「[^」]*」|“[^”]*”|"[^"]*""#)

    /// (独白, 正文)。没写独白就是 ("", 原文)。
    public static func split(_ text: String) -> (monologue: String, body: String) {
        let ns = text as NSString
        let tags = tag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = tags.first else { return ("", trim(text)) }
        let before = ns.substring(to: start.range.location)
        if tags.count >= 2 {
            let end = tags[1]
            let mono = ns.substring(with: NSRange(location: start.range.upperBound, length: end.range.location - start.range.upperBound))
            return (trim(mono), trim(before + ns.substring(from: end.range.upperBound)))
        }
        // 只开不收：独白里用「她 / 他 / TA」指对方，正文才对着对方说「你」——从第一段直接说「你」的开始算正文
        let rest = ns.substring(from: start.range.upperBound)
        let paras = rest.components(separatedBy: try! NSRegularExpression(pattern: #"\n\s*\n"#))
        for (i, p) in paras.enumerated() where i > 0 {
            let plain = quoted.stringByReplacingMatches(in: p, range: NSRange(location: 0, length: (p as NSString).length), withTemplate: "")
            if saysYou.firstMatch(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)) != nil {
                return (trim(paras[..<i].joined(separator: "\n\n")), trim(before + paras[i...].joined(separator: "\n\n")))
            }
        }
        return (trim(rest), trim(before))
    }

    /// 放进 system 的规矩。pronoun = 独白里怎么称呼对方（她 / 他 / TA）；style = 用户自己写的思考风格，空着就不加
    /// 每轮压在 TA 最新那句后面的一行短提醒（10-05 真 key：只放 system 里，聊长了 DeepSeek 就不写独白了；服务器一直每轮都贴）
    public static func hook(zh: Bool, pronoun: String) -> String {
        zh ? "〔独白〕要调工具的先调，先别写字；然后回复最前面先写 [独白]…[/独白]，那是你一个人在想，里面\(pronoun)一直是「\(pronoun)」，一个「你」字都不写；写完一定用 [/独白] 收尾，再换成对\(pronoun)说话。"
           : "〔Monologue〕If you need tools, call them first, before any text; then start the reply with [monologue]…[/monologue] — you thinking alone, where they are always \"\(pronoun)\", never \"you\"; always close it with [/monologue], then switch to talking to them."
    }

    public static func rules(zh: Bool, pronoun: String, style: String) -> String {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if zh {
            var s = """
            想事的方式：每次回复，先在最前面用 [独白] 和 [/独白] 包一段你心里过的东西。第一人称，用「\(pronoun)」指对方，\
            想到什么写什么，不用列计划、不用打草稿。要用工具的话，先调工具、先别写字，结果回来以后再写独白。\
            独白写完，再写真正对\(pronoun)说的话。独白不会发给\(pronoun)，只当你的思考留着。
            """
            if !style.isEmpty { s += "\n独白的写法：\(style)" }
            return s
        }
        var s = """
        How you think: start every reply with what's going through your head, wrapped in [monologue] and [/monologue]. \
        First person, refer to them as "\(pronoun)", write whatever comes up — no plans, no drafts. If you need a tool, \
        call it first without writing anything; write the monologue after the result comes back. Then write what you \
        actually say to them. The monologue is never sent to them; it's kept as your thinking.
        """
        if !style.isEmpty { s += "\nHow to write it: \(style)" }
        return s
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let ns = self as NSString
        var out: [String] = [], last = 0
        for m in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.upperBound
        }
        out.append(ns.substring(from: last))
        return out
    }
}
