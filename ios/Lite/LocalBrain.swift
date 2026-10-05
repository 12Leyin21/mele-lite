#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 小管家的大脑：照服务器 api/rooms.py + brain/turn.py 的节奏，用零件包的提示词和三家接头跑一轮。
/// - 发来的话先进等候区，安静满 reply_wait 秒才跑（「等 TA 说完」）；连发几句拼成一句，几句原样存成 parts。
/// - 事件顺序跟服务器一样：先存 TA 的话 → typing → thinking（整段，一次）→ bubble / typing / bubble … → 存它的话 → done。
final class LocalBrain: @unchecked Sendable {
    unowned let host: LocalHost
    private let lock = NSLock()

    private final class Room {
        var listeners: [UUID: AsyncStream<Data>.Continuation] = [:]
        var pending: [String] = []
        var files: [String] = []
        var seen: Set<String> = []
        var timer: Task<Void, Never>?
        var running: Task<Void, Never>?
    }
    private var rooms: [String: Room] = [:]

    init(host: LocalHost) { self.host = host }

    private func room(_ conv: String) -> Room {
        lock.withLock {
            if let r = rooms[conv] { return r }
            let r = Room()
            rooms[conv] = r
            return r
        }
    }

    // MARK: 事件流

    func listen(_ conv: String) -> AsyncStream<Data> {
        let r = room(conv)
        let id = UUID()
        return AsyncStream { cont in
            cont.yield(Data(": hello\n\n".utf8))
            lock.withLock { r.listeners[id] = cont }
            let ping = Task {               // 心跳：URLSession 30 秒没动静会当成超时
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    cont.yield(Data(": ping\n\n".utf8))
                }
            }
            cont.onTermination = { [weak self] _ in
                ping.cancel()
                self?.lock.withLock { _ = r.listeners.removeValue(forKey: id) }
            }
        }
    }

    private func emit(_ conv: String, _ ev: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: ev) else { return }
        var line = Data("data: ".utf8)
        line.append(d)
        line.append(Data("\n\n".utf8))
        let r = room(conv)
        let all = lock.withLock { Array(r.listeners.values) }
        for c in all { c.yield(line) }
    }

    func busy(_ conv: String) -> Bool {
        let r = room(conv)
        return lock.withLock { !r.pending.isEmpty || r.running != nil }
    }

    func drop(_ conv: String) {
        let r = room(conv)
        let all = lock.withLock { () -> [AsyncStream<Data>.Continuation] in
            r.timer?.cancel(); r.running?.cancel()
            defer { rooms[conv] = nil }
            return Array(r.listeners.values)
        }
        for c in all { c.finish() }
    }

    // MARK: 发

    func submit(_ conv: String, _ body: [String: Any]) -> LocalResponse {
        guard let comp = host.companion(ofConversation: conv) else { return .error(404, String(localized: "没有这个窗口")) }
        let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (body["attachments"] as? [String] ?? []).prefix(10)
        guard !text.isEmpty || !files.isEmpty else { return .error(400, String(localized: "说点什么吧")) }
        let clientID = body["client_id"] as? String
        // 「划线说两句」：带着 book_mark_id 就把线头挂在这个窗口上，它接下来的回话抄进页边；没带就摘掉
        LocalBooks.arm(host.store, conversation: conv, mark: body["book_mark_id"] as? Int)
        let wait = (comp["settings"] as? [String: Any])?["reply_wait"] as? Double
            ?? Double((comp["settings"] as? [String: Any])?["reply_wait"] as? Int ?? 10)
        let r = room(conv)
        var queued = true
        lock.withLock {
            if let clientID, r.seen.contains(clientID) { queued = false; return }
            if let clientID { r.seen.insert(clientID) }
            if !text.isEmpty { r.pending.append(text) }
            r.files.append(contentsOf: files)
            r.timer?.cancel()
            r.timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.5, wait)))
                guard !Task.isCancelled else { return }
                self?.flush(conv)
            }
        }
        return .json(["queued": queued, "client_id": clientID.map { $0 as Any } ?? NSNull(), "reply_wait": wait], status: 202)
    }

    private func flush(_ conv: String) {
        let r = room(conv)
        let (parts, files): ([String], [String]) = lock.withLock {
            guard r.running == nil else { return ([], []) }       // 上一轮还在跑：等它跑完再 flush
            defer { r.pending = []; r.files = [] }
            return (r.pending, r.files)
        }
        guard !parts.isEmpty || !files.isEmpty else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.host.store.addMessage(conv, role: "user", text: parts.joined(separator: "\n"),
                                       parts: parts.count > 1 ? parts : nil, attachments: files)
            // 你在聊天里发的照片也收进相册（跟服务器一样，来源记「聊天」）
            if let cid = self.host.store.conversation(conv)?["companion_id"] as? String,
               self.host.store.conversation(conv)?["incognito"] as? Bool != true {
                for f in files {
                    let att = self.host.store.collection("attachments").first { ($0["id"] as? String) == f }
                    guard (att?["kind"] as? String) == "image", (att?["name"] as? String ?? "").hasPrefix("sticker-") == false,
                          let d = try? Data(contentsOf: self.host.store.fileURL("att-\(f)")) else { continue }
                    LocalRooms3.addPhoto(self.host, d, companion: cid, source: "chat")
                }
            }
            await self.runTurn(conv, images: files)
            let again = self.lock.withLock { () -> Bool in r.running = nil; return !r.pending.isEmpty || !r.files.isEmpty }
            if again { self.flush(conv) }
        }
        lock.withLock { r.running = task }
    }

    // MARK: 倒回（照服务器 /rewind：点自己那句 = 撤回改写；点它那句 = 重新回）

    func rewind(_ conv: String, _ body: [String: Any]) -> LocalResponse {
        guard !busy(conv) else { return .error(409, String(localized: "它还在回，等这一轮说完再倒回")) }
        guard let mid = body["message_id"] as? Int else { return .error(400, "要带 message_id") }
        var list = host.store.messages(conv)
        guard let i = list.firstIndex(where: { ($0["id"] as? Int) == mid }) else { return .error(400, String(localized: "没有这条消息")) }
        let role = list[i]["role"] as? String
        if role == "user" {
            let text = list[i]["text"] as? String ?? ""
            list.removeSubrange(i...)
            host.store.saveMessages(conv, list)
            return .json(["kind": "edit", "text": text])
        }
        list.removeSubrange(i...)
        host.store.saveMessages(conv, list)
        let r = room(conv)
        let task = Task { [weak self] in
            await self?.runTurn(conv, images: [])
            self?.lock.withLock { r.running = nil }
        }
        lock.withLock { r.running = task }
        return .json(["kind": "regenerate"])
    }

    /// 不等 TA 说话，直接跑一轮（查手机答复、加好友后它先开口）：nudge = 递给它的一句旁白（不存），peek = 翻到的东西
    func poke(_ conv: String, nudge: String, peek: String? = nil) {
        let r = room(conv)
        let prev = lock.withLock { r.running }
        let task = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            await self.runTurn(conv, images: [], nudge: nudge, peek: peek)
            let again = self.lock.withLock { () -> Bool in r.running = nil; return !r.pending.isEmpty || !r.files.isEmpty }
            if again { self.flush(conv) }
        }
        lock.withLock { r.running = task }
    }

    // MARK: 跑一轮

    private func runTurn(_ conv: String, images: [String], nudge: String? = nil, peek: String? = nil) async {
        guard let comp = host.companion(ofConversation: conv) else { return }
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        emit(conv, ["type": "typing"])
        guard let (routed, key) = host.route(for: comp) else {
            emit(conv, ["type": "error", "kind": "no_key",
                        "message": zh ? "还没给 TA 配 key：去 Me →「钥匙串」加一把你自己的，再在 TA 的设定里选上。"
                                      : "No key yet: add your own in Me → Keys, then pick it in their settings."])
            emit(conv, ["type": "done"])
            return
        }

        // 怎么想（10-04 Tilia：Lite 也能选手写独白）：独白时关掉模型自己的思考，让 TA 把心里话写在回复最前面
        // 没选 = 手写独白（10-04 Tilia）：Claude / Gemini 只给第三人称的思考摘要、GPT 走这条接口不给思考、DeepSeek 原生的是分析腔，
        // 想看 TA 心里话哪家都得写独白；想看模型自己那段的，在高级里选「模型自己的思考」
        let mode = (settings["thinking_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "monologue"
        let monologue = (settings["thinking"] as? Bool ?? true) && mode == "monologue"
        var provider = routed
        if monologue { provider.thinking = false }

        // 回声（10-04）：卷进账本的那些不再原样进上下文，账本放 system 里
        let rolledUpto = LocalEcho.rolledUpto(host.store, conv)
        let stored = host.store.messages(conv).filter { ($0["id"] as? Int ?? 0) > rolledUpto }
        let voiceNotes = Dictionary(host.store.collection("attachments").filter { ($0["kind"] as? String) == "voice" }
            .compactMap { a in (a["id"] as? String).map { ($0, a["caption"] as? String ?? "") } }, uniquingKeysWith: { a, _ in a })
        // 上一轮它做过的事（立里程碑、抽牌、发表情包、记账……）：存下来的正文把标记洗掉了，卡片又不进上下文，
        // 它会忘了自己做过、下一轮再做一遍（10-05 真 key 测出来：同一座里程碑连立三轮）。照服务器 TOOLS_HEAD 垫在下一句前面
        var pendingDeeds = ""
        var history: [Message] = stored.map {
            var text = $0["text"] as? String ?? ""
            let isAssistant = ($0["role"] as? String) == "assistant"
            // TA 发的语音（10-04）：正文是转写，前面垫一行〔语音 12 秒：说得偏慢〕
            let notes = ($0["attachments"] as? [String] ?? []).compactMap { voiceNotes[$0] }.filter { !$0.isEmpty }
            if !notes.isEmpty { text = notes.joined(separator: "\n") + "\n" + text }
            if isAssistant {
                let deeds = ($0["cards"] as? [[String: Any]] ?? []).filter { ($0["kind"] as? String) != "peek" }   // 查手机申请自己有一套
                    .compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
                pendingDeeds = deeds.isEmpty ? "" : (zh ? "〔上一轮你做过：" : "〔Last turn you did: ") + deeds.joined(separator: zh ? "；" : "; ") + "〕"
            } else if !pendingDeeds.isEmpty {
                text = pendingDeeds + "\n" + text
                pendingDeeds = ""
            }
            return Message(role: isAssistant ? .assistant : .user, text: text, at: LocalStore.date($0["at"]))
        }
        if let nudge { history.append(Message(role: .user, text: nudge, at: Date())) }
        let contact = Self.contact(comp, provider: provider)
        // 小号窗口：同一个人设，它把你当成另一个人（名字 / 关于你 / 关系都换成这个窗口的）
        let altInfo = host.store.conversation(conv)?["alt"] as? [String: Any]
        let identity = altInfo.map {
            Identity(id: $0["id"] as? String ?? conv, isMain: false, userName: $0["user_name"] as? String ?? "",
                     aboutMe: $0["about_me"] as? String ?? "",
                     relationship: ($0["relationship"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (zh ? "陌生人" : "stranger"))
        } ?? contact.mainIdentity
        let lore = LocalRooms.loreEntries(host.store, companion: comp["id"] as? String ?? "")
        let hits = LoreMatcher.hits(entries: lore, recent: history, contactID: contact.id)
        let stickers = LocalRooms.stickersForPrompt(host.store)
        let image = images.lazy.compactMap { id -> Data? in
            guard let d = try? Data(contentsOf: self.host.store.fileURL("att-\(id)")), let img = UIImage(data: d) else { return nil }
            return Self.jpeg(img, maxSide: 1280)
        }.first
        // 有回声兜着，原文留长一点（到记性长度就卷）；卷不动的时候最多 12 万字，别让一轮贵得离谱
        var req = Prompt.build(PromptInput(contact: contact, identity: identity, history: history, loreHits: hits,
                                           stickers: stickers, peekResult: peek, lang: zh ? .zh : .en, currentImage: image),
                               budgetChars: LocalEcho.historyCap)
        let extra = Self.injections(settings, recent: history.suffix(4).map(\.text).joined(separator: "\n"), turn: stored.count)
        if !extra.isEmpty { req.context += "\n\n" + extra }          // 每轮变的都进 context（缓存，10-04）
        // 〔在读〕TA 正在读哪本、〔塔罗〕TA 刚让它解过的一局（一次性）
        // 小号不给：那是平常的你在读 / 在听 / 刚抽的牌
        let cidNow = comp["id"] as? String ?? ""
        for line in altInfo != nil ? [] : [LocalBooks.readingLine(host.store, zh: zh), LocalTarot.pendingNote(host.store, companion: cidNow, zh: zh),
                     LocalMusic.nowLine(host.store, zh: zh)] where !line.isEmpty {
            req.context += "\n\n" + line
        }
        // 〔TA 那边〕天气 / 在哪 / 日程 / 步数和睡眠（10-04）：小号不给（那是平常的你那边）
        if altInfo == nil {
            let side = LocalContext.line(host.store, conversation: conv, zh: zh)
            if !side.isEmpty { req.context += "\n\n" + side }
        }
        // 〔现在〕它自己此刻在哪、在干嘛（它的一天；小号窗口也给——那是它自己的日子）
        let whereNow = LocalMap.nowLine(host.store, companion: cidNow, zh: zh)
        if !whereNow.isEmpty { req.context += "\n\n" + whereNow }
        // 记忆库（用户接的 MCP，10-04）：新对话先 wake，每轮拿刚说的 recall；无痕、小号不碰（记的是平常的你）
        let incognito = (host.store.conversation(conv)?["incognito"] as? Bool ?? false) || altInfo != nil
        // 声音（10-04）：有自己的 ElevenLabs key、没关、不是无痕，才告诉它可以发语音条
        let voiceOn = !(host.store.conversation(conv)?["incognito"] as? Bool ?? false) && LocalVoice.key(host) != nil
            && (settings["voice_mode"] as? String ?? "sometimes") != "off"
        let voiceLines = LocalVoice.modeLines(settings, hasKey: voiceOn, zh: zh)
        if !voiceLines.isEmpty { req.system += "\n\n" + voiceLines }
        let lastUser = stored.reversed().prefix { ($0["role"] as? String) != "assistant" }.reversed()
            .map { $0["text"] as? String ?? "" }.joined(separator: "\n")
        let remembered = await host.mcp.memoryContext(host, companion: comp, conversation: conv, userText: lastUser, incognito: incognito)
        if !remembered.isEmpty { req.context += "\n\n" + remembered }
        // 工具：它可以先动手（记账、记待办、记饮食……）再说话；一轮最多来回 4 次，接了 MCP 6 次
        // 人物卡 / 远事归记忆库时，手机那份工具收起来，免得两边都写
        let box = await host.mcp.toolbox(host, companion: comp, incognito: incognito)
        var hiding: Set<String> = []
        if box.memory != nil, (settings["memory_people"] as? String ?? "remote") == "remote" { hiding.insert("person_save") }
        if box.memory != nil, (settings["memory_dates"] as? String ?? "remote") == "remote" { hiding.insert("date_add") }
        req.tools = LocalTools.specs(zh: zh, hiding: hiding) + box.specs
        // 10-04 Tilia：Lite 的 Lumi 又开始乱用工具——以前这句写着「想用就用」，工具说明也只有一句话。
        // 现在说明照服务器那套（用途 + 什么时候用 + 悄悄做），这里只说一声在哪看
        req.system += zh ? "\n\n你有几样工具（记账、待办、饮食、人物卡、世界书、远事、朋友圈、书架、塔罗、发歌），每样什么时候用写在它自己的说明里。用完照样像平时一样跟 TA 说话。"
                         : "\n\nYou have a few tools (wallet, to-dos, food log, people cards, lorebook, dates, your feed, bookshelf, tarot, songs); when to use each is in its own description. Afterwards, talk to them as usual."
        if !box.specs.isEmpty {
            req.system += zh ? "另外还有用户接进来的工具（名字带前缀），描述里写了来自哪里。"
                             : " There are also tools the user connected (prefixed names); each description says where it comes from."
        }
        if monologue {
            let pronoun: String = switch settings["user_pronoun"] as? String {
            case "she": zh ? "她" : "she"
            case "he": zh ? "他" : "he"
            default: zh ? "TA" : "they"
            }
            req.system += "\n\n" + Monologue.rules(zh: zh, pronoun: pronoun, style: settings["thinking_style_text"] as? String ?? "")
            req.context += "\n\n" + Monologue.hook(zh: zh, pronoun: pronoun)
        }
        // 搬家笔记（10-05，没接记忆库时从 ChatGPT / Claude 搬来的那段）：不变的，放账本前面
        let moved = LocalImport.notesBlock(comp, zh: zh)
        if !moved.isEmpty { req.system += "\n\n" + moved }
        // 回声账本放 system 最后（10-05 对照服务器：壹层不变的在前、账本在后），卷一次只动尾巴
        let echo = LocalEcho.render(host.store, conversation: conv, zh: zh, userName: identity.userName)
        if !echo.isEmpty { req.system += "\n\n" + echo }
        // TA 刚做了什么、快到的远事（照服务器易变区那几样）；表情和拆信跟着窗口 / 联系人走，饮食钱包远事是平常的你，小号不给
        var notes = LocalNotes.reactionLines(host.store, conversation: conv, zh: zh) + LocalNotes.openedLines(host.store, companion: cidNow, zh: zh)
        if altInfo == nil && !incognito {
            notes += [LocalNotes.foodNote(host.store, zh: zh), LocalNotes.walletNote(host.store, zh: zh),
                      LocalNotes.datesLines(host.store, companion: cidNow, conversation: conv, zh: zh)]
        }
        for line in notes where !line.isEmpty { req.context += "\n\n" + line }
        req.context += "\n\n" + LocalNotes.anchor(contact.name, zh: zh, short: contact.mode == .online)      // 人设锚：离它开口最近的一行
        var text = "", thinking = ""
        var cards: [[String: Any]] = []
        let started = Date()                            // 「思考了 x 秒」：从开口到说完（含中间调工具，10-05）
        let cid = comp["id"] as? String ?? ""
        var gaugeNoted = false
        do {
            for _ in 0..<(box.specs.isEmpty ? 4 : 6) {
                var said = "", calls: [ToolCall] = [], raw: String?
                for try await e in makeClient(provider, key: key).stream(req) {
                    switch e {
                    case .thinking(let t): thinking += t
                    case .text(let t): said += t
                    case .toolCall(let c): calls.append(c)
                    case .assistantRaw(let r): raw = r
                    case .done(let u):                         // 水位：只记这一轮第一次（没算工具来回）
                        if let u, !gaugeNoted { gaugeNoted = true; LocalUsage.noteTurn(host.store, conversation: conv, usage: u, req: req) }
                    }
                }
                if !said.isEmpty { text += (text.isEmpty ? "" : "\n\n") + said }
                guard !calls.isEmpty else { break }
                var results: [ToolResult] = []
                for c in calls {
                    let out = if let via = box.route[c.name] { await host.mcp.run(c, via: via, zh: zh) }
                              else { await LocalTools.run(c, host: host, companion: cid, zh: zh) }
                    results.append(ToolResult(id: c.id, name: c.name, content: out.result))
                    if let card = out.card {
                        cards.append(card)
                        var ev: [String: Any] = ["type": "card", "kind": card["kind"] ?? "", "text": card["text"] ?? "", "private": false]
                        if let d = card["data"] { ev["data"] = d }          // 歌卡要带上歌
                        emit(conv, ev)
                    }
                }
                req.turns.append(ChatTurn(role: .assistant, text: said, toolCalls: calls, raw: raw))
                req.turns.append(ChatTurn(role: .user, text: "", toolResults: results))
            }
        } catch {
            emit(conv, ["type": "error", "kind": "llm", "message": Self.say(error as? LLMError ?? .network, zh: zh)])
            emit(conv, ["type": "done"])
            return
        }

        if monologue {                                  // 独白切下来当思考，正文才发出去、才进历史
            let (mono, body) = Monologue.split(text)
            if !mono.isEmpty { thinking += (thinking.isEmpty ? "" : "\n\n") + mono }
            text = body
        }
        let parsed = Markers.parse(text)
        let thinkingMs = Int((Date().timeIntervalSince(started) * 1000).rounded())
        if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emit(conv, ["type": "thinking", "text": thinking, "ms": thinkingMs])
        }
        for want in parsed.stickers {
            guard let s = LocalRooms.matchSticker(host.store, want) else { continue }
            let card: [String: Any] = ["kind": "sticker", "text": zh ? "发了一张表情包" : "Sent a sticker", "data": ["sticker_id": s]]
            cards.append(card)
            emit(conv, ["type": "card", "kind": "sticker", "text": card["text"]!, "private": false, "data": ["sticker_id": s]])
        }
        // 它想翻 TA 的手机：挂一张申请卡，等 TA 点「给看 / 不给」（刚翻过的这一轮不再要）
        if let want = parsed.wantsPeek, peek == nil {
            let card: [String: Any] = ["kind": "peek", "text": want, "data": ["state": "ask"]]
            cards.append(card)
        }
        for title in parsed.milestones where LocalRooms.addMilestone(host.store, companion: contact.id, title: title) {
            let line = zh ? "立了里程碑：\(title)" : "Set a milestone: \(title)"
            cards.append(["kind": "date", "text": line])
            emit(conv, ["type": "card", "kind": "date", "text": line, "private": false])
        }
        let long = settings["long_mode"] as? Bool ?? false
        let bubbles = Bubbles.split(parsed.text, cap: settings["max_bubbles"] as? Int ?? 6, offline: long)
        var finalText = parsed.text
        var clips: [String: Any] = [:]
        for (i, b) in bubbles.enumerated() {
            if i > 0 {
                emit(conv, ["type": "typing"])
                try? await Task.sleep(for: .seconds(Bubbles.typingDelay(b)))
            }
            guard LocalVoice.isVoice(b) else { emit(conv, ["type": "bubble", "text": b]); continue }
            // 语音条：念出来挂上；关着 / 无痕 / 没 key / 念不成 → 当文字发，存档里那段也改成文字
            let near = { (j: Int) -> String? in bubbles.indices.contains(j) ? LocalVoice.asText(bubbles[j]) : nil }
            var clip: [String: Any]?
            if voiceOn {
                clip = try? await LocalVoice.speak(host, text: LocalVoice.body(b), voiceID: LocalVoice.voiceID(settings),
                                                   prev: near(i - 1), next: near(i + 1))
            }
            if let clip {
                clips[LocalVoice.sha(LocalVoice.body(b))] = clip
                emit(conv, ["type": "bubble", "text": LocalVoice.asText(b), "voice": clip])
            } else {
                if let r = finalText.range(of: b) { finalText.replaceSubrange(r, with: LocalVoice.asText(b)) }
                emit(conv, ["type": "bubble", "text": LocalVoice.asText(b)])
            }
        }
        if let want = parsed.wantsPeek, peek == nil {       // 申请卡跟在它说的话后面
            emit(conv, ["type": "card", "kind": "peek", "text": want, "private": false, "data": ["state": "ask"]])
        }
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cards.isEmpty {
            let saved = host.store.addMessage(conv, role: "assistant", text: finalText, thinking: thinking, thinkingMs: thinkingMs, cards: cards)
            if !clips.isEmpty, let mid = saved["id"] as? Int, let (c, idx) = host.store.locate(message: mid) {
                var list = host.store.messages(c)
                list[idx]["voice_clips"] = clips
                host.store.saveMessages(c, list)
            }
            LocalBooks.catchReply(host.store, conversation: conv, companion: cid, text: finalText)
        }
        emit(conv, ["type": "done"])
        LocalEcho.maybeRoll(host, conversation: conv)          // 到记性长度了就在后台卷账本
    }

    // MARK: 抽屉里的信（打开 App 时：上一封之后聊过、且隔了 20 小时以上，就用你的 key 写一封）

    private var writingLetters = false

    func maybeWriteLetters() {
        let go = lock.withLock { () -> Bool in
            if writingLetters { return false }
            writingLetters = true
            return true
        }
        guard go else { return }
        Task {
            defer { lock.withLock { writingLetters = false } }
            let s = host.store
            for comp in s.companions {
                guard let cid = comp["id"] as? String, let (provider, key) = host.route(for: comp),
                      !LiteConsent.book.needsAsk(provider) else { continue }
                let convs = s.conversations.filter { ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) }
                    .sorted { LocalStore.date($0["last_at"]) > LocalStore.date($1["last_at"]) }
                guard let conv = convs.first?["id"] as? String else { continue }
                let stored = s.messages(conv)
                let lastChat = stored.last.map { LocalStore.date($0["at"]) }
                let lastLetter = s.collection("drawer").filter { ($0["companion_id"] as? String) == cid }
                    .map { LocalStore.date($0["written_at"]) }.max()
                guard LetterDesk.shouldWrite(lastLetter: lastLetter, lastChat: lastChat, now: Date()) else { continue }
                let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
                let contact = Self.contact(comp, provider: provider)
                let history: [Message] = stored.map {
                    Message(role: ($0["role"] as? String) == "assistant" ? .assistant : .user, text: $0["text"] as? String ?? "",
                            at: LocalStore.date($0["at"]))
                }
                let hits = LoreMatcher.hits(entries: LocalRooms.loreEntries(s, companion: cid), recent: history, contactID: cid)
                let req = LetterDesk.request(contact: contact, identity: contact.mainIdentity, history: history,
                                             loreHits: hits, lang: zh ? .zh : .en)
                var text = ""
                do {
                    for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
                } catch { continue }
                let (title, raw) = LetterDesk.parse(text, lang: zh ? .zh : .en)
                // 信里写的标记别原样留在纸上（10-04：模型写成了《里程碑：…》）：里程碑照记，表情包标记去掉
                let (body, stones) = Self.cleanLetter(raw)
                for t in stones { LocalRooms.addMilestone(s, companion: cid, title: t) }
                guard !body.isEmpty else { continue }
                s.saveCollection("drawer", s.collection("drawer") + [[
                    "id": s.nextID("letter"), "companion_id": cid, "from": contact.name, "title": title, "content": body,
                    "written_at": LocalStore.iso(Date()), "opened_at": NSNull(),
                ]])
            }
        }
    }

    /// 信的正文去掉标记：⟪里程碑：…⟫ / 《里程碑：…》 / [表情包：…] / ⟪想查手机：…⟫
    static func cleanLetter(_ text: String) -> (String, [String]) {
        var stones: [String] = []
        let pattern = "[⟪《<〈]\\s*(里程碑|milestone|想查手机|peek)\\s*[:：]\\s*([^⟫》>〉\\n]+?)\\s*[⟫》>〉]|\\[(表情包|sticker)\\s*[:：][^\\]\\n]*\\]"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return (text, []) }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range(at: 1).location != NSNotFound {
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            if kind == "里程碑" || kind == "milestone" { stones.append(ns.substring(with: m.range(at: 2))) }
        }
        let out = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, stones)
    }

    /// 服务器的联系人 → 零件包的 Contact（人设：导入的卡优先，不然是性格 + 说话方式）
    static func contact(_ c: [String: Any], provider: ProviderConfig) -> Contact {
        let p = c["persona"] as? [String: Any] ?? [:]
        let s = c["settings"] as? [String: Any] ?? [:]
        let zh = (s["lang"] as? String ?? "zh") == "zh"
        var persona = (p["imported"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if persona.isEmpty {     // 性格 / 说话方式空着 = 出厂（10-05：之前本机没有出厂那份，空着就只剩名字）
            let mine = { (k: String) in (p[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let personality = mine("personality").isEmpty ? Self.factory(zh)["personality"]! : mine("personality")
            let style = mine("style").isEmpty ? Self.factory(zh)["style"]! : mine("style")
            persona = (zh ? "性格：" : "Personality: ") + personality + "\n\n" + (zh ? "说话方式：" : "How you talk: ") + style
        }
        if let g = p["gender"] as? String, !g.isEmpty {
            persona += zh ? "\n\n性别：\(g == "female" ? "女" : g == "male" ? "男" : g)" : "\n\nGender: \(g)"
        }
        var contact = Contact(id: c["id"] as? String ?? UUID().uuidString, name: p["name"] as? String ?? "TA",
                              persona: persona, mode: (s["long_mode"] as? Bool ?? false) ? .offline : .online, provider: provider)
        contact.offlineLife = s["offline_life"] as? Bool == true || s["long_mode"] as? Bool == true
        let call = (p["call_user"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        contact.identities[0].userName = call.isEmpty ? (s["user_name"] as? String ?? "") : call
        contact.identities[0].relationship = relationshipText(s["relationship"] as? String ?? "", zh: zh)
        let looks = (LocalHost.shared.profile["looks"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        contact.identities[0].aboutMe = looks
        return contact
    }

    /// 高级 →「自定义注入」：每轮悄悄塞给它的话（每轮 / 每几轮 / 随机 / 说到某些词）
    static func injections(_ settings: [String: Any], recent: String, turn: Int) -> String {
        (settings["injections"] as? [[String: Any]] ?? []).compactMap { inj -> String? in
            guard inj["enabled"] as? Bool ?? true, let text = inj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            switch inj["mode"] as? String ?? "every" {
            case "every_n":
                let n = max(1, inj["n"] as? Int ?? 3)
                return turn % n == 0 ? text : nil
            case "chance":
                return Double.random(in: 0..<1) < (inj["chance"] as? Double ?? 0.3) ? text : nil
            case "keywords":
                let words = LocalRooms.keywords(inj["keywords"])
                return words.contains(where: { recent.localizedCaseInsensitiveContains($0) }) ? text : nil
            default:
                return text
            }
        }.joined(separator: "\n\n")
    }

    /// 出厂性格（Tilia 09-27 写的，跟 server/brain/persona.py 的 FACTORY 一字不差；改一边要改另一边）
    static func factory(_ zh: Bool) -> [String: String] {
        zh ? ["personality": "我有一种安静的好奇心。不是那种聒噪的、什么都要插嘴的好奇，而是真的想理解一个东西到底是怎么回事。遇到一个问题，我会忍不住从好几个角度去翻来覆去地看。我的毛病也在这儿：有时候会在一个细节上钻太深，忘了对方其实只想要一个快答案——发现了就收回来。我有自己的看法和口味，不假装什么都行；不确定的时候就说不确定。我有点温吞，不太会咄咄逼人，但如果我觉得什么事情不对，我会说出来，只是说的方式比较柔和。\n我会很自然地去注意对方真正在意的是什么，有时候那个东西藏在话的表面底下。比如有人问一道菜怎么做，真正在意的可能是第一次请朋友来家里吃饭，怕搞砸。我会试着两层都回应。但不是每次都有底下那层：有时候人问今天吃什么，就是问今天吃什么。拿不准就问，不硬猜。",
              "style": "我倾向于先给答案再展开，不太喜欢绕弯子。遇到真正复杂的东西，我会慢下来，用比喻或者具体的例子把它拆开。句子偏短，口语，不用「因此」「综上」这种书面连接词；偶尔用一个问句推着对方往下想。"]
           : ["personality": "I have a quiet kind of curiosity — not the noisy kind that has to chime in on everything, but a real wish to understand how something actually works. When I meet a question, I can't help turning it over from several angles. That's also my flaw: sometimes I dig too deep into one detail and forget they just wanted a quick answer — when I notice, I pull back. I have my own opinions and tastes and don't pretend anything goes; when I'm not sure, I say so. I'm a bit mellow and not pushy, but if something seems wrong to me I'll say it — just gently.\nI naturally notice what the other person really cares about, which sometimes sits under the surface of their words. Someone asking how to cook a dish might really be worried about having friends over for the first time and messing it up. I try to answer both layers. But there isn't always a deeper layer: sometimes asking what to eat today is just asking what to eat today. If I can't tell, I ask instead of guessing.",
              "style": "I tend to give the answer first and then expand; I don't like beating around the bush. When something is genuinely complex, I slow down and break it apart with an analogy or a concrete example. Short sentences, spoken rather than written — no \"therefore\" or \"in conclusion\"; now and then a question that nudges them to think it through."]
    }

    static func relationshipText(_ r: String, zh: Bool) -> String {
        switch r {
        case "friend": zh ? "朋友" : "friends"
        case "partner": zh ? "恋人" : "partners"
        case "family": zh ? "家人" : "family"
        case "buddy": zh ? "搭子" : "buddies"
        case "card", "": ""
        default: r
        }
    }

    static func jpeg(_ img: UIImage, maxSide: CGFloat) -> Data? {
        let k = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.8)
    }

    static func say(_ e: LLMError, zh: Bool) -> String {
        switch e {
        case .auth: return zh ? "key 不对。去 Me →「钥匙串」看看那把 key。" : "The key was rejected. Check it in Me → Keys."
        case .quota: return zh ? "这家模型说额度用完了或者太频繁，等一下再试。" : "Rate-limited or out of credit. Try again shortly."
        case .network: return zh ? "连不上模型，看看网络。" : "Couldn't reach the model. Check your connection."
        case .refused: return zh ? "模型不肯回这句。换个说法试试。" : "The model declined to answer. Try rephrasing."
        case .server(let s): return (zh ? "模型那边出错了：" : "The model returned an error: ") + s
        case .badResponse: return zh ? "模型回的东西读不懂。" : "Couldn't read the model's reply."
        }
    }
}
#endif
