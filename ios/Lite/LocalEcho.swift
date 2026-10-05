#if LITE
import Foundation
import MeleLiteCore

/// 回声（10-04 Tilia：Lite 也要卷账本）。照正式版 server/brain/ledger.py + turn.roll 搬到手机里：
/// 一轮聊完，喂给模型的量（上一轮实际 token）到了「记性长度」就卷——从尾巴往前留 40 条或 1 万字，更早的按天写进账本，
/// 远的模糊、近的清楚（今天 2500 字 / 昨天 1000 / 前天 400 / 更早一两句，英文 ×3）；每段逐句回查原文、查长度和人称，
/// 不合格换一个模型再写，还不行这次不卷（原文先留着，下次再试）。另留 6 条它自己的原话当腔调样本。
/// 卷完账本固定放在 system 里（只在卷的时候动，缓存不会无故作废）。思路来自 @onecrazyfishhh。
/// 存在窗口上：echo（天 → 一段）、echo_samples、rolled_upto（这条消息号及以前的不再进上下文）、echo_fails。
enum LocalEcho {
    static let keepCount = 40
    static let keepChars = 10_000
    static let voiceSamples = 6
    static let sampleChars = 300
    static let dayQuotas = [2500, 1000, 400]
    static let oldDayQuota = 100
    static let quotaSlack = 1.3
    static let maxDays = 14
    static let entryRatio = 0.05
    static let entryMin = 80, entryMax = 500
    static let chunkChars = 12_000
    static let ageLo = 0.7
    static let pieceMinQuota = 40
    static let pieceAim = 0.8
    static let nameLimit = 2
    static let minRatio = 0.3
    static let maxDrop = 0.5
    /// 记性长度没设：上一轮喂了这么多 token 就卷（设定里「中 · 3 万」）
    static let defaultHighWater = 30_000
    /// 卷不动时上下文里原文的上限（字）
    static let historyCap = 120_000

    static func scale(_ zh: Bool) -> Int { zh ? 1 : 3 }

    // MARK: - 读（LocalBrain 拼上下文用）

    static func rolledUpto(_ s: LocalStore, _ conv: String) -> Int { s.conversation(conv)?["rolled_upto"] as? Int ?? 0 }

    static func days(_ s: LocalStore, _ conv: String) -> [String: String] {
        (s.conversation(conv)?["echo"] as? [String: String]) ?? [:]
    }

    /// 放进 system 的那段：账本 + 腔调样本
    static func render(_ s: LocalStore, conversation conv: String, zh: Bool, userName: String) -> String {
        let ds = days(s, conv).filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let samples = s.conversation(conv)?["echo_samples"] as? [String] ?? []
        var out: [String] = []
        if !ds.isEmpty {
            let u = who(userName, zh)
            out.append(zh ? "〔账本〕更早的对话，远的模糊、近的清楚（账里的「我」是你，「\(u)」是对方）："
                          : "〔Ledger〕Earlier conversation — older is hazier, recent is clearer (\"I\" is you, \"\(u)\" is them):")
            out.append(ds.keys.sorted().map { "## \($0)\n\(ds[$0]!)" }.joined(separator: "\n"))
        }
        if !samples.isEmpty {
            out.append(zh ? "〔腔调样本〕你之前的几句原话，照这个腔调接着说：" : "〔Voice samples〕A few of your own earlier lines — keep this voice:")
            out.append(contentsOf: samples.map { "- 「\($0)」" })
        }
        return out.joined(separator: "\n")
    }

    static func highWater(_ settings: [String: Any]) -> Int {
        (settings["memory_length"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? defaultHighWater
    }

    // MARK: - 卷

    private static let busyLock = NSLock()
    nonisolated(unsafe) private static var busy: Set<String> = []

    /// 一轮聊完调：上一轮喂的量到线了就在后台卷（同一个窗口不会同时卷两次）
    static func maybeRoll(_ host: LocalHost, conversation conv: String) {
        guard let c = host.store.conversation(conv), let comp = host.companion(ofConversation: conv) else { return }
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let tokens = ((c["gauge"] as? [String: Any])?["tokens"] as? Int) ?? 0
        guard tokens >= highWater(settings) else { return }
        guard busyLock.withLock({ busy.insert(conv).inserted }) else { return }
        Task {
            defer { _ = busyLock.withLock { busy.remove(conv) } }
            await roll(host, conversation: conv)
        }
    }

    struct Msg { let id: Int; let role: String; let text: String; let at: Date }

    static func roll(_ host: LocalHost, conversation conv: String) async {
        let s = host.store
        guard let comp = host.companion(ofConversation: conv) else { return }
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        let upto = rolledUpto(s, conv)
        let msgs = s.messages(conv).compactMap { m -> Msg? in
            guard let id = m["id"] as? Int, id > upto else { return nil }
            return Msg(id: id, role: (m["role"] as? String) == "assistant" ? "assistant" : "user",
                       text: m["text"] as? String ?? "", at: LocalStore.date(m["at"]))
        }
        let (rolled, _) = plan(msgs)
        guard !rolled.isEmpty else { return }
        let legs = models(host, comp)
        guard !legs.isEmpty else { return }
        let name = ((comp["persona"] as? [String: Any])?["name"] as? String) ?? "TA"
        let userName = (comp["persona"] as? [String: Any])?["call_user"] as? String ?? ""
        let tz = (settings["tz"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
        let today = dayKey(Date(), tz)
        var ds = days(s, conv)

        // ① 写新账：按天拆开，每天（太长分段）单独写一小段接上去；任何一段写不出来 = 这次不卷
        for (d, chunks) in transcripts(rolled, tz: tz, zh: zh, userName: userName).sorted(by: { $0.key < $1.key }) {
            if age(d, today) >= maxDays { continue }
            for t in chunks {
                guard let entry = await writeEntry(legs, transcript: t, day: d, existing: ds[d] ?? "", name: name, zh: zh, userName: userName) else {
                    fail(s, conv)
                    return
                }
                ds[d] = join(ds[d] ?? "", entry, zh: zh)
            }
        }
        // ② 压旧天：超了天龄配额 ×1.3 的天单独压；压不动先留着
        for (d, a, quota) in overQuota(ds, today: today, zh: zh) {
            if let short = await ageDay(legs, text: ds[d] ?? "", day: d, age: a, quota: quota, name: name, zh: zh, userName: userName) {
                ds[d] = short
            }
        }
        // ③ 14 天以前的丢掉
        for d in ds.keys where age(d, today) >= maxDays { ds[d] = nil }
        guard var c = s.conversation(conv) else { return }
        c["echo"] = ds
        c["rolled_upto"] = rolled.last!.id
        c["echo_samples"] = rolled.filter { $0.role == "assistant" }.map { String($0.text.prefix(sampleChars)) }.suffix(voiceSamples).map { $0 }
        c["echo_fails"] = 0
        c["echo_at"] = LocalStore.iso(Date())
        c["gauge"] = nil                       // 卷完了，上一轮的水位不作数；下一轮重新量
        s.saveConversation(c)
    }

    private static func fail(_ s: LocalStore, _ conv: String) {
        guard var c = s.conversation(conv) else { return }
        c["echo_fails"] = (c["echo_fails"] as? Int ?? 0) + 1
        s.saveConversation(c)
    }

    /// 从尾巴往前留 40 条或 1 万字（先到为准），至少最后一来一回；留下的第一条得是 TA 说的
    static func plan(_ msgs: [Msg]) -> (rolled: [Msg], kept: [Msg]) {
        var n = 0, chars = 0
        for m in msgs.reversed() {
            if n >= keepCount || chars + m.text.count > keepChars { break }
            n += 1; chars += m.text.count
        }
        n = max(n, min(2, msgs.count))
        var start = msgs.count - n
        while start < msgs.count && msgs[start].role != "user" { start += 1 }
        if start == msgs.count { start = msgs.lastIndex { $0.role == "user" } ?? 0 }
        return (Array(msgs[..<start]), Array(msgs[start...]))
    }

    /// 写账 / 压旧天用的模型：设定里选了单独的钥匙就先用它，打回了换聊天那把兜底；只有一把就给两次机会。不开思考。
    static func models(_ host: LocalHost, _ comp: [String: Any]) -> [(ProviderConfig, String)] {
        let settings = comp["settings"] as? [String: Any] ?? [:]
        guard let chat = host.route(for: comp), !LiteConsent.book.needsAsk(chat.0) else { return [] }
        var first = chat
        if let kid = settings["echo_key_id"] as? String, !kid.isEmpty {
            var alt = comp
            alt["key_id"] = kid
            if let r = host.route(for: alt), !LiteConsent.book.needsAsk(r.0) { first = r }
        }
        func plain(_ r: (ProviderConfig, String)) -> (ProviderConfig, String) {
            (ProviderConfig(kind: r.0.kind, baseURL: r.0.baseURL, model: r.0.model, thinking: false), r.1)
        }
        return [plain(first), plain(chat)]
    }

    // MARK: - 天、配额

    static func dayKey(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz
        return f.string(from: d)
    }

    static func age(_ day: String, _ today: String) -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let a = f.date(from: day), let b = f.date(from: today) else { return 0 }
        return max(0, Int((b.timeIntervalSince(a) / 86400).rounded()))
    }

    static func quota(age: Int, zh: Bool) -> Int { (age < dayQuotas.count ? dayQuotas[age] : oldDayQuota) * scale(zh) }

    static func entryBudget(_ chars: Int, zh: Bool) -> Int {
        let k = scale(zh)
        return max(entryMin * k, min(entryMax * k, Int((Double(chars) * entryRatio).rounded())))
    }

    static func overQuota(_ ds: [String: String], today: String, zh: Bool) -> [(String, Int, Int)] {
        ds.keys.sorted().compactMap { d in
            let a = age(d, today)
            guard a < maxDays else { return nil }
            let q = quota(age: a, zh: zh)
            return Double((ds[d] ?? "").count) > Double(q) * quotaSlack ? (d, a, q) : nil
        }
    }

    static func who(_ userName: String, _ zh: Bool, _ form: String = "subj") -> String {
        let n = userName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        if zh { return "TA" }
        return ["subj": "they", "Subj": "They", "obj": "them"][form] ?? "they"
    }

    static func speaker(_ role: String, zh: Bool, userName: String) -> String {
        role == "user" ? (userName.trimmingCharacters(in: .whitespaces).isEmpty ? (zh ? "TA" : "Them") : userName) : (zh ? "我" : "Me")
    }

    /// 按 TA 那边的日期拆开，每天拼成「[时:分] 我：……」；一天太长分几段（每段 ≤ 1.2 万字）
    static func transcripts(_ msgs: [Msg], tz: TimeZone, zh: Bool, userName: String) -> [String: [String]] {
        let sep = zh ? "：" : ": "
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"; hm.timeZone = tz
        var lines: [String: [String]] = [:]
        for m in msgs {
            let line = "[\(hm.string(from: m.at))] \(speaker(m.role, zh: zh, userName: userName))\(sep)\(m.text)"
            lines[dayKey(m.at, tz), default: []].append(String(line.prefix(chunkChars)))
        }
        return lines.mapValues { ls in
            var chunks: [String] = [], cur = ""
            for l in ls {
                if !cur.isEmpty && cur.count + 1 + l.count > chunkChars { chunks.append(cur); cur = "" }
                cur = cur.isEmpty ? l : cur + "\n" + l
            }
            chunks.append(cur)
            return chunks
        }
    }

    // MARK: - 文字处理（逐句回查、验收、拼接）

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let cjkRun = rx("[\\u3400-\\u9fff]+")
    private static let word = rx("[A-Za-z][A-Za-z'’\\-]+|\\d[\\d.:]*")
    private static let hardRx = rx("[A-Za-z][A-Za-z'’\\-]{2,}|\\d[\\d.:]+")
    private static let hardEn = rx("(?<=\\s)[A-Z][A-Za-z'’\\-]{2,}|\\d[\\d.:]+")
    private static let dateHead = rx("^\\s*(?:#+\\s*)?(?:\\d{4}-\\d{2}-\\d{2}|\\d{1,2}月\\d{1,2}日)[：:]?\\s*")

    private static func all(_ r: NSRegularExpression, _ s: String) -> [String] {
        r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// 拆句：中文句末标点之后、英文句点 + 空白、换行
    static func sentences(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\n" { out.append(cur); cur = ""; i += 1; continue }
            cur.append(ch)
            if "。！？!?；;".contains(ch) { out.append(cur); cur = "" }
            else if ch == ".", i + 1 < chars.count, chars[i + 1].isWhitespace { out.append(cur); cur = "" }
            i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func grams(_ text: String) -> Set<String> {
        var g = Set<String>()
        for run in all(cjkRun, text) {
            let a = Array(run)
            if a.count >= 2 { for i in 0..<(a.count - 1) { g.insert(String(a[i...i + 1])) } }
        }
        for w in all(word, text) { g.insert(w.lowercased()) }
        return g
    }

    static func hard(_ sent: String) -> [String] {
        if !all(cjkRun, sent).isEmpty { return all(hardRx, sent) }
        guard let sp = sent.firstIndex(of: " ") else { return [] }
        let rest = " " + sent[sent.index(after: sp)...]
        return all(hardEn, String(rest)) + all(hardRx, String(sent[..<sp])).filter { $0.first?.isNumber == true }
    }

    /// 逐句回查原文：一句里不到三成内容在原文里、或冒出原文没有的英文名 / 数字，这句就扔；扔掉超过一半整段作废
    static func ground(_ text: String, source: String) -> String? {
        let src = grams(source)
        let srcHard = Set(all(hardRx, source).map { $0.lowercased() })
        var kept: [String] = [], total = 0, dropped = 0
        for sent in sentences(text) {
            let g = grams(sent)
            if g.isEmpty { kept.append(sent); continue }
            total += 1
            let invented = hard(sent).filter { !srcHard.contains($0.lowercased()) }
            if Double(g.intersection(src).count) / Double(g.count) < minRatio || !invented.isEmpty { dropped += 1; continue }
            kept.append(sent)
        }
        if total == 0 || Double(dropped) / Double(total) > maxDrop { return nil }
        var out = ""
        for sent in kept {
            out = out.isEmpty ? sent : out + ("。！？；".contains(out.last!) ? "" : " ") + sent
        }
        return out
    }

    /// 写到字数上限硬停在半句（10-05 真 key：「……麻辣烫宽粉，嘱」）：退回到最后一个句末；整段都没句末就原样
    static func wholeSentences(_ text: String) -> String {
        let ends = Set("。！？!?…」』”")
        guard let last = text.last, !ends.contains(last), !(last == "." && !text.hasSuffix("..")),
              let cut = text.lastIndex(where: { ends.contains($0) || $0 == "." }) else { return text }
        return String(text[...cut])
    }

    static func defect(_ text: String, maxLen: Int, name: String) -> Bool {
        if text.count < 10 || text.count > maxLen { return true }
        guard !name.isEmpty else { return false }
        return text.lowercased().components(separatedBy: name.lowercased()).count - 1 > nameLimit
    }

    static func oneLine(_ text: String, zh: Bool) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = dateHead.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return t.replacingOccurrences(of: "\\s*\\n+\\s*", with: zh ? "" : " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func join(_ a: String, _ b: String, zh: Bool) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty || b.isEmpty { return a.isEmpty ? b : a }
        if let l = a.last, "。！？!?…」』”）).".contains(l) { return zh ? a + b : "\(a) \(b)" }
        return zh ? "\(a)。\(b)" : "\(a). \(b)"
    }

    static func pieces(_ text: String, size: Int) -> [String] {
        var out: [String] = [], cur = ""
        for sent in sentences(text) {
            if !cur.isEmpty && cur.count + sent.count > size { out.append(cur); cur = "" }
            cur = cur.isEmpty || "。！？；".contains(cur.last!) ? cur + sent : "\(cur) \(sent)"
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: - 写账、压旧天（提示词照正式版）

    static func dayLabel(_ day: String, zh: Bool) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return day }
        if zh { return "\(p[1])月\(p[2])日" }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[max(0, min(11, p[1] - 1))]) \(p[2])"
    }

    static func writePrompt(_ transcript: String, day: String, existing: String, name: String, zh: Bool, userName: String) -> (String, Int) {
        let limit = entryBudget(transcript.count, zh: zh)
        let user = who(userName, zh), obj = who(userName, zh, "obj"), label = speaker("user", zh: zh, userName: userName)
        let last = String(existing.suffix(120))
        if zh {
            let tail = existing.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "- 这一天已有的账最后一句是：「\(last)」——接着往下写，别重复。\n"
            return ("""
            下面是\(name)和\(user)的一段对话，全部发生在 \(dayLabel(day, zh: true))。把它写成一段 \(limit) 字以内的账，接在这一天已有的账后面。

            【角色与人称】
            - 全文用\(name)的第一人称写：\(name)一律写「我」，**不许出现「\(name)」这个名字，也不许用「它」「他」「她」指\(name)**。对方写「\(user)」。
            - 说话人只看每行开头的标签（「我：」是\(name)，「\(label)：」是对方），不按语气改判。

            【写什么】
            - 事实脉络：发生了什么、谁说了哪句关键的话、做了什么决定或约定、情绪在哪里转弯。
            - 场景没结束就写停在哪一步。不抄原句，不写抒情和描写。
            - 只写对话里真有的事，不续写，不补对话里没有的人名、数字、计划。
            \(tail)
            【输出】一段中文正文，\(limit) 字以内，不带日期、不分行、不加前言。

            ⟪对话开始⟫
            \(transcript)
            ⟪对话结束⟫

            再说一遍：\(limit) 字以内。
            """, limit)
        }
        let tail = existing.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "- The day's ledger so far ends with: \"\(last)\" — carry on from there, don't repeat it.\n"
        return ("""
        Below is part of a conversation between \(name) and \(obj), all on \(dayLabel(day, zh: false)). Write it up as one ledger paragraph of at most \(limit) characters, to be appended to that day's existing ledger.

        [Voice and person]
        - Write in \(name)'s first person: \(name) is always "I". **Never write the name "\(name)", and never call \(name) "it", "he" or "she".** The other person is "\(user)".
        - Who said what is decided only by the label at the start of each line ("Me:" is \(name), "\(label):" is the other person), never by tone.

        [What to write]
        - The factual thread: what happened, the key lines and who said them, decisions or agreements made, where the mood turned.
        - If a scene hasn't finished, say where it stopped. Don't quote lines verbatim; no lyrical description.
        - Only what is in the conversation. Don't continue it, and don't add names, numbers or plans that aren't there.
        \(tail)
        [Output] One paragraph of plain English, at most \(limit) characters, no date, no line breaks, no preamble.

        ⟪conversation start⟫
        \(transcript)
        ⟪conversation end⟫

        Once more: at most \(limit) characters.
        """, limit)
    }

    static func agePrompt(_ text: String, day: String, age a: Int, quota: Int, name: String, zh: Bool, userName: String) -> String {
        let user = who(userName, zh), User = who(userName, zh, "Subj"), obj = who(userName, zh, "obj")
        let lo = Int((Double(quota) * ageLo).rounded())
        if zh {
            let howOld = a < 3 ? ["今天", "昨天", "前天"][a] : "\(a) 天前"
            let how = a >= 3
                ? "- 大幅删除细节、原因和过程，只保留「主语 + 最终结果/决定」。\n  例：原句「因为吵架，\(user)晚饭没吃去了公园」→ 压缩为「\(user)没吃晚饭」。\n- 只留一两句：这一天最要紧的事或决定。"
                : "- 删除过程和细节描写，保留原因、结果和情绪转折。\n  例：原句「因为吵架，\(user)晚饭没吃，一个人去了公园，回来眼睛是红的」→ 压缩为「吵架后\(user)没吃晚饭去了公园，回来哭过」。\n- 保留事实脉络和情绪转折，删掉细节描写、重复和抒情。"
            return """
            下面是\(name)的账本里 \(dayLabel(day, zh: true))（\(howOld)）这一天的记录。账里的「我」是\(name)，「\(user)」是对方。

            【核心指令：对这段记录执行二次压缩】
            ⚠️ 注意：这段记录不是最终成品，必须进行二次裁剪与重构，不能原样交回！
            \(how)
            - 写成一段 \(lo)～\(quota) 字的新概要，替换掉原来的。

            【角色与人称】
            - 照原记录用第一人称：「我」还是「我」，**不许出现「\(name)」这个名字，也不许用「它」「他」「她」指我**。对方写「\(user)」。
            - 谁说的、谁做的照原记录，不改判——「\(user)夸我」不能写成「我夸\(user)」。

            【写什么】
            - 只写原记录里真有的事，不补原记录没有的人名、数字、计划。不认识的名字照抄，不加括号注解、不猜。

            【输出】一段中文正文，\(lo)～\(quota) 字（别写得比 \(lo) 字短，细节是要留的），不带日期、不分行、不加前言。

            ⟪记录开始⟫
            \(text)
            ⟪记录结束⟫

            再说一遍：\(lo)～\(quota) 字。
            """
        }
        let howOld = a < 3 ? ["today", "yesterday", "the day before yesterday"][a] : "\(a) days ago"
        let how = a >= 3
            ? "- Cut details, reasons and process hard; keep only \"who + final outcome/decision\".\n  e.g. \"After the argument \(user) skipped dinner and went to the park\" → \"\(User) skipped dinner\".\n- One or two sentences: the most important thing or decision of that day."
            : "- Cut the process and descriptive detail; keep causes, outcomes and turns of mood.\n  e.g. \"After the argument \(user) skipped dinner, went to the park alone and came back with red eyes\" → \"After the argument \(user) skipped dinner, went to the park and came back having cried\".\n- Keep the factual thread and turns of mood; drop description, repetition and lyricism."
        return """
        Below is the entry for \(dayLabel(day, zh: false)) (\(howOld)) from \(name)'s ledger. "I" in it is \(name); "\(user)" is the other person.

        [Core instruction: compress this entry a second time]
        ⚠️ Note: this entry is NOT a finished product. It must be cut down and rewritten — do not hand it back as it is!
        \(how)
        - Write one new summary paragraph of \(lo)–\(quota) characters to replace the old one.

        [Voice and person]
        - Keep the first person: "I" stays "I". **Never write the name "\(name)", and never call me "it", "he" or "she".** The other person is "\(user)".
        - Keep who said and did what exactly as recorded — "\(user) praised me" must not become "I praised \(obj)".

        [What to write]
        - Only what is in the entry. Don't add names, numbers or plans that aren't there. Copy unknown names as they are; no guesses or notes in brackets.

        [Output] One paragraph of plain English, \(lo)–\(quota) characters (not shorter than \(lo) — details are meant to stay), no date, no line breaks, no preamble.

        ⟪entry start⟫
        \(text)
        ⟪entry end⟫

        Once more: \(lo)–\(quota) characters.
        """
    }

    /// 短活：按顺序试每个模型，过了回查原文、长度、人称就用；都不行返回 nil
    static func short(_ legs: [(ProviderConfig, String)], prompt: String, source: String, maxLen: Int,
                      name: String, zh: Bool, userName: String) async -> String? {
        let source = "\(source)\n\(who(userName, zh))"
        for (p, key) in legs {
            let req = ChatRequest(system: zh ? "你是一个精简的记账员。" : "You are a concise ledger keeper.",
                                  turns: [ChatTurn(role: .user, text: prompt)], maxTokens: 4000)
            var text = ""
            do { for try await e in makeClient(p, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { continue }
            guard let g = ground(oneLine(text, zh: zh), source: source).map(wholeSentences),
                  !defect(g, maxLen: maxLen, name: name) else { continue }
            return g
        }
        return nil
    }

    static func writeEntry(_ legs: [(ProviderConfig, String)], transcript: String, day: String, existing: String,
                           name: String, zh: Bool, userName: String) async -> String? {
        let (prompt, limit) = writePrompt(transcript, day: day, existing: existing, name: name, zh: zh, userName: userName)
        return await short(legs, prompt: prompt, source: "\(transcript)\n\(existing)", maxLen: Int(Double(limit) * 1.5),
                           name: name, zh: zh, userName: userName)
    }

    /// 压旧天：DeepSeek 一大段压不动、小段压得动（09-27 考试），长的先按句切 600 字小块各压
    static func ageDay(_ legs: [(ProviderConfig, String)], text: String, day: String, age a: Int, quota q: Int,
                       name: String, zh: Bool, userName: String) async -> String? {
        let piece: Int? = legs.first.map { $0.0.model.lowercased().contains("deepseek") } == true ? 600 : nil
        var result: String?
        if let size = piece, text.count > size {
            var out = ""
            let floor = pieceMinQuota * scale(zh)
            for part in pieces(text, size: size) {
                let pq = max(floor, Int((Double(q) * pieceAim * Double(part.count) / Double(text.count)).rounded()))
                let got = await short(legs, prompt: agePrompt(part, day: day, age: a, quota: pq, name: name, zh: zh, userName: userName),
                                      source: part, maxLen: max(pq * 2, part.count - 1), name: name, zh: zh, userName: userName)
                out = join(out, got ?? part, zh: zh)
            }
            result = out
        } else {
            result = await short(legs, prompt: agePrompt(text, day: day, age: a, quota: q, name: name, zh: zh, userName: userName),
                                 source: text, maxLen: q * 2, name: name, zh: zh, userName: userName)
        }
        guard let r = result, r.count < text.count else { return nil }
        return r
    }

    // MARK: - 接口：TA 的设定里看 / 改

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts, s = host.store
        switch (r.method, p.count) {
        case ("GET", 3) where p[0] == "companions" && p[2] == "echo":
            let convs = s.conversations.filter { ($0["companion_id"] as? String) == p[1] && !(($0["echo"] as? [String: String]) ?? [:]).isEmpty }
                .sorted { LocalStore.date($0["last_at"]) > LocalStore.date($1["last_at"]) }
            return .json(convs.map { c -> [String: Any] in
                let ds = (c["echo"] as? [String: String]) ?? [:]
                let alt = (c["alt"] as? [String: Any])?["user_name"] as? String ?? ""
                return ["conversation": c["id"] ?? "", "title": c["title"] ?? "", "alt_name": alt,
                        "days": ds.keys.sorted(by: >).map { ["day": $0, "text": ds[$0]!] },
                        "samples": c["echo_samples"] ?? [String](), "at": c["echo_at"] ?? NSNull(), "fails": c["echo_fails"] ?? 0]
            })
        case ("PUT", 3) where p[0] == "conversations" && p[2] == "echo":
            guard var c = s.conversation(p[1]), let day = r.json["day"] as? String else { return .error(404, String(localized: "没有这个窗口")) }
            var ds = (c["echo"] as? [String: String]) ?? [:]
            let text = (r.json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ds[day] = text.isEmpty ? nil : text
            c["echo"] = ds
            s.saveConversation(c)
            return .json(["ok": true])
        default:
            return nil
        }
    }
}
#endif
