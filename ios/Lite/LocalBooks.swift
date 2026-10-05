#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 书架（10-04 Tilia：Lite 也要能读书）：照 server/api/routes_books.py + brain/books.py 搬进手机。
/// - 导入 txt（UTF-8 / GBK），按「第 X 章 / Chapter X / 卷」切章；切不出来每 3000 字一段。正文是一个文件，章只记起止（UTF-16 下标）。
/// - 页边：划线、批注、往来（parent_id 挂在线头底下）。author = "user" 或联系人编号。
/// - 「划线说两句」：那句带着 book_mark_id 发进聊天，线头挂在窗口上，它接下来半小时的回话抄一份进页边。
/// - 它知道 TA 在读哪（〔在读〕，3 分钟内翻过页才有）；工具 book 能翻到 TA 那一页、在页边留一笔（每天最多 3 笔，不剧透）。
enum LocalBooks {
    static let maxBytes = 20 * 1024 * 1024
    static let chunk = 3000
    static let pageChars = 1500
    static let marksPerDay = 3
    static let readingFresh: TimeInterval = 3 * 60
    static let threadTTL: TimeInterval = 30 * 60

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        guard p.first == "books" else { return nil }
        let s = host.store
        let bid = p.count > 1 ? Int(p[1]) : nil
        switch (r.method, p.count) {
        case ("GET", 1): return .json(list(s))
        case ("POST", 1): return add(s, r)
        case ("PATCH", 2):
            let title = (r.json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .error(400, String(localized: "书名不能空着")) }
            guard let b = update(s, bid, { $0["title"] = String(title.prefix(100)) }) else { return noBook }
            return .json(publicOut(s, b))
        case ("DELETE", 2):
            guard let b = book(s, bid) else { return noBook }
            s.saveCollection("books", s.collection("books").filter { ($0["id"] as? Int) != bid })
            s.saveCollection("book-marks", s.collection("book-marks").filter { ($0["book_id"] as? Int) != bid })
            s.saveCollection("book-reading", s.collection("book-reading").filter { ($0["book_id"] as? Int) != bid })
            s.removeFile(b["file"] as? String ?? "")
            s.removeFile("book-cover-\(bid ?? 0)")
            cache.removeValue(forKey: bid ?? 0)
            return .empty
        case ("PUT", 3) where p[2] == "cover":
            guard book(s, bid) != nil else { return noBook }
            guard let f = r.form.files["file"]?.first, let img = UIImage(data: f.data),
                  let jpg = LocalBrain.jpeg(img, maxSide: 1200) else { return .error(400, String(localized: "这张图打不开")) }
            s.saveFile(jpg, name: "book-cover-\(bid ?? 0)")
            _ = update(s, bid) { $0["cover"] = true }
            return .empty
        case ("GET", 3) where p[2] == "cover":
            guard let d = try? Data(contentsOf: s.fileURL("book-cover-\(bid ?? 0)")) else { return .error(404, String(localized: "没有封面")) }
            return .data(d, mime: "image/jpeg")
        case ("GET", 3) where p[2] == "chapters":
            guard let b = book(s, bid) else { return noBook }
            return .json(chapters(b).enumerated().map { i, c in ["index": i, "title": c.title, "length": c.end - c.start] })
        case ("GET", 4) where p[2] == "chapters":
            guard let b = book(s, bid), let i = Int(p[3]), let text = chapterText(s, b, i) else { return .error(404, String(localized: "没有这一章")) }
            return .json(["index": i, "title": chapters(b)[i].title, "text": text])
        case ("GET", 3) where p[2] == "marks":
            guard book(s, bid) != nil else { return noBook }
            let ch = r.query["chapter"].flatMap(Int.init)
            return .json(s.collection("book-marks").filter { ($0["book_id"] as? Int) == bid && (ch == nil || ($0["chapter"] as? Int) == ch) }
                .sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) })
        case ("POST", 3) where p[2] == "marks":
            let b = r.json
            let comp = (b["companion_id"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            return addMark(s, bid ?? 0, chapter: b["chapter"] as? Int ?? 0, quote: b["quote"] as? String ?? "",
                           note: b["note"] as? String ?? "", author: "user", pos: b["pos"] as? Int ?? -1,
                           companion: comp, parent: b["parent_id"] as? Int)
        case ("DELETE", 4) where p[2] == "marks":
            let mid = Int(p[3])
            let all = s.collection("book-marks")
            guard all.contains(where: { ($0["id"] as? Int) == mid && ($0["book_id"] as? Int) == bid && ($0["author"] as? String) == "user" }) else {
                return .error(404, String(localized: "没有这条（它写的删不了）"))
            }
            s.saveCollection("book-marks", all.filter { ($0["id"] as? Int) != mid && ($0["parent_id"] as? Int) != mid })
            return .empty
        case ("POST", 3) where p[2] == "reading":
            let j = r.json
            guard let b = book(s, bid) else { return noBook }
            let n = max(1, chapters(b).count)
            let ch = max(0, min(j["chapter"] as? Int ?? 0, n - 1))
            _ = update(s, bid) {
                $0["at_chapter"] = ch
                $0["at_page"] = max(0, j["page"] as? Int ?? 0)
                $0["page_count"] = max(0, j["page_count"] as? Int ?? 0)
                $0["furthest"] = max($0["furthest"] as? Int ?? 0, ch)
                $0["read_at"] = LocalStore.iso(Date())
            }
            let secs = min(600, j["seconds"] as? Int ?? 0)
            if secs > 0 {
                var rows = s.collection("book-reading")
                let day = today()
                if let i = rows.firstIndex(where: { ($0["book_id"] as? Int) == bid && ($0["day"] as? String) == day }) {
                    rows[i]["seconds"] = (rows[i]["seconds"] as? Int ?? 0) + secs
                } else {
                    rows.append(["book_id": bid ?? 0, "day": day, "seconds": secs])
                }
                s.saveCollection("book-reading", rows)
            }
            return .empty
        default: return nil
        }
    }

    private static var noBook: LocalResponse { .error(404, String(localized: "没有这本书")) }

    // MARK: - 书

    struct Chapter { let title: String; let start: Int; let end: Int }

    static func book(_ s: LocalStore, _ id: Int?) -> [String: Any]? {
        guard let id else { return nil }
        return s.collection("books").first { ($0["id"] as? Int) == id }
    }

    @discardableResult
    static func update(_ s: LocalStore, _ id: Int?, _ change: (inout [String: Any]) -> Void) -> [String: Any]? {
        var all = s.collection("books")
        guard let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return nil }
        change(&all[i])
        s.saveCollection("books", all)
        return all[i]
    }

    static func chapters(_ b: [String: Any]) -> [Chapter] {
        (b["chapters"] as? [[Any]] ?? []).compactMap { c in
            guard c.count == 3, let t = c[0] as? String, let a = c[1] as? Int, let z = c[2] as? Int else { return nil }
            return Chapter(title: t, start: a, end: z)
        }
    }

    /// 正文按书缓存一份（翻章不用每次读文件）
    nonisolated(unsafe) private static var cache: [Int: NSString] = [:]
    private static let cacheLock = NSLock()

    static func fullText(_ s: LocalStore, _ b: [String: Any]) -> NSString? {
        let id = b["id"] as? Int ?? 0
        if let t = cacheLock.withLock({ cache[id] }) { return t }
        guard let d = try? Data(contentsOf: s.fileURL(b["file"] as? String ?? "")), let t = String(data: d, encoding: .utf8) else { return nil }
        let ns = t as NSString
        cacheLock.withLock { cache = [id: ns] }          // 只留一本，够用
        return ns
    }

    static func chapterText(_ s: LocalStore, _ b: [String: Any], _ i: Int) -> String? {
        let cs = chapters(b)
        guard cs.indices.contains(i), let t = fullText(s, b) else { return nil }
        let c = cs[i]
        let start = min(c.start, t.length), end = min(c.end, t.length)
        return t.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    static func publicOut(_ s: LocalStore, _ b: [String: Any]) -> [String: Any] {
        let id = b["id"] as? Int ?? 0
        let n = chapters(b).count
        let at = b["at_chapter"] as? Int ?? 0, page = b["at_page"] as? Int ?? 0, pc = b["page_count"] as? Int ?? 0
        let raw = pc > 0 ? Double(at) + Double(page + 1) / Double(pc) : Double(at)
        let progress = n > 0 ? min(1, raw / Double(n)) : 0
        let secs = s.collection("book-reading").first { ($0["book_id"] as? Int) == id && ($0["day"] as? String) == today() }?["seconds"] as? Int ?? 0
        let marks = s.collection("book-marks").filter { ($0["book_id"] as? Int) == id }.count
        return ["id": id, "title": b["title"] ?? "", "chapters": n, "at_chapter": at, "at_page": page, "page_count": pc,
                "progress": (progress * 10000).rounded() / 10000, "has_cover": b["cover"] as? Bool ?? false,
                "read_at": b["read_at"] ?? NSNull(), "today_minutes": secs / 60, "marks": marks, "created_at": b["created_at"] ?? ""]
    }

    static func list(_ s: LocalStore) -> [[String: Any]] {
        s.collection("books").sorted {
            max(LocalStore.date($0["read_at"]), LocalStore.date($0["created_at"])) > max(LocalStore.date($1["read_at"]), LocalStore.date($1["created_at"]))
        }.map { publicOut(s, $0) }
    }

    static func add(_ s: LocalStore, _ r: LocalRequest) -> LocalResponse {
        let form = r.form
        guard let f = form.files["file"]?.first else { return .error(400, String(localized: "选一本 txt 吧")) }
        guard f.data.count <= maxBytes else { return .error(400, String(localized: "书太大了（最多 20MB）")) }
        var title = (form.fields["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = f.name.lowercased()
        guard lower.hasSuffix(".txt") || lower.hasSuffix(".text") || !title.isEmpty else { return .error(400, String(localized: "先只认 txt")) }
        guard var text = decode(f.data) else { return .error(400, String(localized: "这个文件读不出来（只认 UTF-8 和 GBK 的 txt）")) }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error(400, String(localized: "这本书是空的")) }
        if title.isEmpty { title = ((f.name as NSString).deletingPathExtension as String) }
        if title.isEmpty { title = String(localized: "未命名") }
        let id = s.nextID("book")
        let file = "book-\(id).txt"
        s.saveFile(Data(text.utf8), name: file)
        let b: [String: Any] = ["id": id, "title": String(title.prefix(100)), "file": file,
                                "chapters": split(text).map { [$0.title, $0.start, $0.end] as [Any] },
                                "cover": false, "at_chapter": 0, "at_page": 0, "page_count": 0, "furthest": 0,
                                "read_at": NSNull(), "created_at": LocalStore.iso(Date())]
        s.saveCollection("books", s.collection("books") + [b])
        return .json(publicOut(s, b), status: 201)
    }

    static func decode(_ d: Data) -> String? {
        if let t = String(data: d, encoding: .utf8) { return t }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: d, encoding: String.Encoding(rawValue: gb))
    }

    private static let head = try! NSRegularExpression(
        pattern: #"^\s*(第[零〇一二三四五六七八九十百千万两0-9]{1,8}[章节回卷部集篇][^\n]{0,40}|(?:Chapter|CHAPTER)\s+[0-9IVXLCivxlc]+\b[^\n]{0,60}|卷[零〇一二三四五六七八九十0-9]{1,4}[^\n]{0,30}|序[章言]?|楔子|尾声|后记|番外[^\n]{0,30})\s*$"#,
        options: [.anchorsMatchLines])

    /// 找得到两个以上章节标题就按标题切；否则每 3000 字一段（尽量断在换行）。下标是 UTF-16 的（NSString）。
    static func split(_ text: String) -> [Chapter] {
        let ns = text as NSString
        let heads = head.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [Chapter] = []
        if heads.count >= 2 {
            let first = heads[0].range.location
            if !ns.substring(to: first).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Chapter(title: "开头", start: 0, end: first))
            }
            for (i, h) in heads.enumerated() {
                let end = i + 1 < heads.count ? heads[i + 1].range.location : ns.length
                let t = ns.substring(with: h.range).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(Chapter(title: String(t.prefix(60)), start: h.range.location, end: end))
            }
            return out
        }
        var pos = 0, n = 1
        while pos < ns.length {
            var end = min(ns.length, pos + chunk)
            if end < ns.length {
                let window = NSRange(location: pos + chunk / 2, length: end - (pos + chunk / 2))
                let cut = ns.range(of: "\n", options: .backwards, range: window)
                if cut.location != NSNotFound { end = cut.location + 1 }
            }
            out.append(Chapter(title: "第 \(n) 段", start: pos, end: end))
            pos = end; n += 1
        }
        return out.isEmpty ? [Chapter(title: "全文", start: 0, end: 0)] : out
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - 页边

    static func addMark(_ s: LocalStore, _ bid: Int, chapter: Int, quote: String, note: String, author: String,
                        pos: Int, companion: String?, parent: Int?) -> LocalResponse {
        guard let b = book(s, bid) else { return noBook }
        let quote = String(quote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        var chapter = chapter, companion = companion, parent = parent
        let all = s.collection("book-marks")
        if let pid = parent {
            guard let root = all.first(where: { ($0["id"] as? Int) == pid && ($0["book_id"] as? Int) == bid }) else {
                return .error(400, String(localized: "没有这道划线"))
            }
            parent = root["parent_id"] as? Int ?? pid
            chapter = root["chapter"] as? Int ?? 0
            companion = companion ?? (root["companion_id"] as? String)
        } else if quote.isEmpty {
            return .error(400, String(localized: "要划哪一句？"))
        }
        guard chapters(b).indices.contains(chapter) else { return .error(400, String(localized: "没有这一章")) }
        guard !quote.isEmpty || !note.isEmpty else { return .error(400, String(localized: "写点什么吧")) }
        let m: [String: Any] = ["id": s.nextID("book-mark"), "book_id": bid, "chapter": chapter, "quote": quote, "note": note,
                                "pos": pos, "author": author, "companion_id": companion ?? NSNull(), "parent_id": parent ?? NSNull(),
                                "created_at": LocalStore.iso(Date())]
        s.saveCollection("book-marks", all + [m])
        return .json(m, status: 201)
    }

    // MARK: - 划线说两句：线头挂在窗口上

    /// 发消息时带了 book_mark_id 就挂上；没带就摘掉（跟服务器一样）
    static func arm(_ s: LocalStore, conversation: String, mark: Int?) {
        var all = s.read("book-threads.json") as? [String: [String: Any]] ?? [:]
        if let mark, s.collection("book-marks").contains(where: { ($0["id"] as? Int) == mark }) {
            all[conversation] = ["mark_id": mark, "armed_at": LocalStore.iso(Date())]
        } else {
            all.removeValue(forKey: conversation)
        }
        s.write("book-threads.json", all)
    }

    /// 它这一轮的回话：线头还挂着（半小时内）就抄一份进页边
    static func catchReply(_ s: LocalStore, conversation: String, companion: String, text: String) {
        var all = s.read("book-threads.json") as? [String: [String: Any]] ?? [:]
        guard let t = all[conversation], let mid = t["mark_id"] as? Int else { return }
        guard Date().timeIntervalSince(LocalStore.date(t["armed_at"])) <= threadTTL else {
            all.removeValue(forKey: conversation)
            s.write("book-threads.json", all)
            return
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let root = s.collection("book-marks").first(where: { ($0["id"] as? Int) == mid }),
              let bid = root["book_id"] as? Int else { return }
        _ = addMark(s, bid, chapter: 0, quote: "", note: clean, author: companion, pos: -1, companion: companion, parent: mid)
    }

    // MARK: - 它那边：〔在读〕和工具

    static func readingNow(_ s: LocalStore) -> [String: Any]? {
        s.collection("books").filter { Date().timeIntervalSince(LocalStore.date($0["read_at"])) < readingFresh }
            .max { LocalStore.date($0["read_at"]) < LocalStore.date($1["read_at"]) }
    }

    static func readingLine(_ s: LocalStore, zh: Bool) -> String {
        guard let b = readingNow(s) else { return "" }
        let cs = chapters(b)
        guard !cs.isEmpty else { return "" }
        let at = min(b["at_chapter"] as? Int ?? 0, cs.count - 1), page = b["at_page"] as? Int ?? 0, pc = b["page_count"] as? Int ?? 0
        let title = b["title"] as? String ?? ""
        if zh {
            return "〔在读〕TA 正在读《\(title)》\(cs[at].title)\(pc > 0 ? "，这一章第 \(page + 1)/\(pc) 页" : "")。想看 TA 这一页写了什么，用 book(action=\"page\")。"
        }
        return "〔Reading〕They're reading \"\(title)\", \(cs[at].title)\(pc > 0 ? ", page \(page + 1)/\(pc) of this chapter" : ""). To see this page, use book(action=\"page\")."
    }

    static func pageText(_ s: LocalStore, _ b: [String: Any]) -> String {
        let ch = b["at_chapter"] as? Int ?? 0, page = b["at_page"] as? Int ?? 0, pc = b["page_count"] as? Int ?? 0
        guard let text = chapterText(s, b, ch), !text.isEmpty else { return "" }
        let ns = text as NSString
        let mid = pc > 0 ? Int(Double(ns.length) * (Double(page) + 0.5) / Double(pc)) : pageChars / 2
        let start = max(0, mid - pageChars / 2)
        return ns.substring(with: NSRange(location: start, length: min(pageChars, ns.length - start)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let toolSpec = ToolSpec(
        name: "book",
        description: "用途：TA 的书架。〔在读〕说 TA 正在读的时候，page=看 TA 这一页写了什么；读到真想说的一句，mark=在页边留一笔（quote 是原文里一字不差的一句，note 是你想说的，可以不写），TA 翻到会看到你的笔迹——不是每次都留，每天最多 3 笔，不剧透 TA 没读到的地方。shelf=看书架上有什么、各读到哪。",
        parametersJSON: #"{"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["shelf","page","mark"]},"id":{"type":"integer","description":"哪本书（shelf 给的编号）；不填 = TA 正在读的那本"},"quote":{"type":"string","description":"mark：原文里的一句，一字不差"},"note":{"type":"string","description":"mark：你想在页边说的一句"}}}"#)

    static func runTool(_ a: [String: Any], host: LocalHost, companion: String) -> LocalTools.Outcome {
        let s = host.store
        let action = a["action"] as? String ?? ""
        if action == "shelf" {
            let rows = list(s)
            guard !rows.isEmpty else { return .init(result: "书架还是空的。", card: nil) }
            let lines = rows.map { "#\($0["id"] ?? 0)《\($0["title"] ?? "")》读到第 \(($0["at_chapter"] as? Int ?? 0) + 1)/\($0["chapters"] ?? 0) 章（\(Int(($0["progress"] as? Double ?? 0) * 100))%）" }
            return .init(result: lines.joined(separator: "\n"), card: nil)
        }
        let b = (a["id"] as? Int).flatMap { book(s, $0) } ?? readingNow(s)
            ?? s.collection("books").max { LocalStore.date($0["read_at"]) < LocalStore.date($1["read_at"]) }
        guard let b else { return .init(result: "TA 书架上还没有书。", card: nil) }
        let title = b["title"] as? String ?? ""
        let cs = chapters(b)
        switch action {
        case "page":
            let text = pageText(s, b)
            let ch = cs.indices.contains(b["at_chapter"] as? Int ?? 0) ? cs[b["at_chapter"] as? Int ?? 0].title : ""
            return .init(result: text.isEmpty ? "这一页是空的。" : "《\(title)》\(ch)，TA 现在这一页大概是：\n\(text)", card: nil)
        case "mark":
            let quote = (a["quote"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (a["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return .init(result: "mark 要带 quote（原文里的一句）", card: nil) }
            let dayStart = Calendar.current.startOfDay(for: Date())
            let today = s.collection("book-marks").filter {
                ($0["author"] as? String) == companion && ($0["parent_id"] as? Int) == nil && LocalStore.date($0["created_at"]) >= dayStart
            }.count
            guard today < marksPerDay else { return .init(result: "今天在书里留过好几笔了，留到明天吧。", card: nil) }
            let furthest = min(b["furthest"] as? Int ?? 0, cs.count - 1)
            guard furthest >= 0, let ch = stride(from: furthest, through: 0, by: -1).first(where: { chapterText(s, b, $0)?.contains(quote) ?? false }),
                  let text = chapterText(s, b, ch) else {
                return .init(result: "书里 TA 读过的部分没找到这一句（要一字不差地引原文）。", card: nil)
            }
            let pos = (text as NSString).range(of: quote).location
            _ = addMark(s, b["id"] as? Int ?? 0, chapter: ch, quote: quote, note: note, author: companion,
                        pos: pos == NSNotFound ? -1 : pos, companion: companion, parent: nil)
            let snip = quote.count > 40 ? String(quote.prefix(40)) + "…" : quote
            return .init(result: "划好了。TA 翻到那一页会看到你的笔迹。", card: ["kind": "book", "text": "在《\(title)》里划了一句：\(snip)"])
        default:
            return .init(result: "action 只能是 shelf / page / mark", card: nil)
        }
    }
}
#endif
