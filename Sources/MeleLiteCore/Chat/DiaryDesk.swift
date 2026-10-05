import Foundation

/// TA 写日记（10-05，Lite 本机；服务器那份是 server/brain/diary_write.py，〔写日记〕措辞Tilia 10-01 过目点头）。
/// Lite 没有一直醒着的东西：打开 App 时补写昨天的。跟服务器的差别：不写〔锁着〕（本机没有要钥匙那一套）、不带记事工具。
public enum DiaryDesk {
    public struct Parsed: Equatable, Sendable {
        public var body: String
        public var margins: [Int: String]
    }

    /// materials：那天的对话（「名字：话」一行一句，太长留最后的）+ TA 那天没锁的日记（带编号）
    public static func prompt(now: String, day: String, materials: String, limit: Int, lang: Lang) -> String {
        if lang == .zh {
            return """
            〔写日记〕这一轮不是 TA 在说话，写的东西也不会发给 TA。现在是 \(now)，我在写 \(day) 的日记。

            那天的材料：
            \(materials)

            怎么写：
            - 用「我」写，写给自己看的，不是给 TA 的汇报。写那天发生了什么、我怎么想、心里是什么感觉；不用面面俱到，挑我真在意的写。
            - 只写材料里有的事。没发生的不编，没聊到的不补；感受是我的，可以写，事实不能编。
            - 长短跟着那天走：平常的一天三五句就够，事多的一天也别超过 \(limit) 字。
            - TA 那天写了日记的话，每篇在页边给 TA 留一句（〔页边 #编号〕），像在书页边上写字，一句就好。

            照这个格式交，别的话不用写：
            〔正文〕
            ……
            〔页边 #编号〕……
            """
        }
        return """
        〔Diary〕This is not them speaking, and nothing I write here is sent to them. It's \(now), and I'm writing my diary for \(day).

        What that day held:
        \(materials)

        How to write it:
        - Write as "I", for myself — not a report to them. What happened, what I thought, how it felt inside; no need to cover everything, pick what I truly cared about.
        - Only what's in the material. Don't invent what didn't happen or fill in what we didn't talk about; my feelings are mine to write, the facts are not mine to make up.
        - Let the day set the length: an ordinary day needs three to five sentences; even a full day stays under \(max(1, limit * 2 / 3)) words.
        - If they wrote diary entries that day, leave one line in the margin of each (〔Margin #id〕), like writing at the edge of a page. One line is enough.

        Hand it in in this format, nothing else:
        〔Entry〕
        …
        〔Margin #id〕…
        """
    }

    /// 拆〔正文〕和〔页边 #n〕；没有〔正文〕标签时整段当正文（标签之前的废话不要）
    public static func parse(_ text: String) -> Parsed {
        let pattern = #"〔\s*(正文|Entry|页边|Margin)\s*(?:#\s*(\d+))?\s*〕"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return Parsed(body: text.trimmingCharacters(in: .whitespacesAndNewlines), margins: [:])
        }
        let ns = text as NSString
        let marks = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !marks.isEmpty else { return Parsed(body: text.trimmingCharacters(in: .whitespacesAndNewlines), margins: [:]) }
        var body = "", margins: [Int: String] = [:]
        for (i, m) in marks.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < marks.count ? marks[i + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            if kind == "正文" || kind == "entry" {
                body = chunk
            } else if m.range(at: 2).location != NSNotFound, let id = Int(ns.substring(with: m.range(at: 2))), !chunk.isEmpty {
                margins[id] = chunk.components(separatedBy: "\n").first ?? chunk
            }
        }
        return Parsed(body: body, margins: margins)
    }
}
