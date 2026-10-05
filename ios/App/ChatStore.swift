import Foundation
import SwiftUI

/// 聊天流里的一行（一个气泡 / 一段思考 / 一张动作卡片）。
///
/// 服务器存的是「一句一条」：它的一轮是一整条（正文 + 思考 + 卡片），TA 连发的几句拼成一条。
/// 屏幕上要拆开——它的话按服务器切好的 bubbles 一泡一泡，思考链、卡片各占一行。
/// 行号 = 消息号 × 64 + 槽位，这样同一条消息刷新几遍行号都不变，列表不会闪。
struct ChatItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case text
        case thinking
        case card(String)          // 卡片种类（remember / search / manual …）
        case song(SongCardData)    // 歌卡（09-30）：画在消息流里，不收进头像下的动作卡
        case sticker(Int)          // 它发的表情包（10-01）：一张图片气泡，编号 = 表情包编号
        case deeds([Deed])         // 它这一轮做过的事（10-03 Tilia：不挂动作卡片了，折成「做了几件事」）
    }

    /// 做过的一件事：种类 + 服务器给的「动作：内容」那一句
    struct Deed: Hashable {
        let kind: String
        let text: String
    }

    /// 歌、表情包、专注提议还单独成一行；其余的动作并进「做了几件事」
    static func isDeed(_ kind: String) -> Bool { kind != "focus" && !kind.hasPrefix("peek") }

    var id: Int
    /// 服务器消息号；本机回显、这一轮还在推的是 nil
    var messageID: Int?
    let mine: Bool
    var kind: Kind
    var text: String
    var at: Date
    /// 标记表情：只挂在它那句的最后一个气泡上
    var reaction: String?
    var attachments: [AttachmentDTO] = []
    /// 语音条（10-03）：它用 🎤 标的那条，服务器念好的那段
    var voice: VoiceRef?
    /// 思考那一行：这一轮想了多久（毫秒，10-05）
    var thinkingMs: Int?

    var isPending: Bool { messageID == nil }

    // MARK: 行号

    static let slots = 64
    /// 它那一轮：0 = 思考，1…15 = 卡片，16… = 气泡
    static let thinkingSlot = 0
    static let cardSlot = 1
    static let bubbleSlot = 16

    static func rowID(message: Int, slot: Int) -> Int { message * slots + min(slot, slots - 1) }

    /// 本机的行（回显、这一轮还在推的）从一个很大的数往上取，排序永远在服务器的后面
    static let localBase = Int.max - 10_000_000

    /// 服务器的一条 → 屏幕上的几行
    static func rows(of m: MessageDTO) -> [ChatItem] {
        let mine = m.role == "user"
        var out: [ChatItem] = []
        // 搬家搬来的每段开头一行灰字（10-05）：排在这条最前面（借上一条的最后一格，正常消息用不到第 64 格）
        if let d = m.divider, !d.isEmpty {
            out.append(ChatItem(id: m.id * slots - 1, messageID: m.id, mine: false, kind: .card("divider"), text: d, at: m.at))
        }
        var bubbles = m.bubbles ?? [m.text]
        if mine {
            if bubbles.count > slots { bubbles = Array(bubbles.prefix(slots - 1)) + [bubbles.dropFirst(slots - 1).joined(separator: "\n")] }
            for (i, text) in bubbles.enumerated() {
                out.append(ChatItem(id: rowID(message: m.id, slot: i), messageID: m.id, mine: true, kind: .text,
                                    text: text, at: m.at, attachments: i == 0 ? (m.attachments ?? []) : []))
            }
            return out
        }
        if !m.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(ChatItem(id: rowID(message: m.id, slot: thinkingSlot), messageID: m.id, mine: false,
                                kind: .thinking, text: m.thinking, at: m.at, thinkingMs: m.thinkingMs))
        }
        var slot = cardSlot
        let deeds = (m.cards ?? []).filter { $0.song == nil && $0.stickerID == nil && ChatItem.isDeed($0.kind) }
        if !deeds.isEmpty {
            out.append(ChatItem(id: rowID(message: m.id, slot: slot), messageID: m.id, mine: false,
                                kind: .deeds(deeds.map { ChatItem.Deed(kind: $0.kind, text: $0.text) }), text: "", at: m.at))
            slot += 1
        }
        for card in m.cards ?? [] where slot < bubbleSlot && !card.kind.hasPrefix("peek") && !(card.song == nil && card.stickerID == nil && ChatItem.isDeed(card.kind)) {
            out.append(ChatItem(id: rowID(message: m.id, slot: slot), messageID: m.id, mine: false,
                                kind: card.song.map { .song($0) } ?? card.stickerID.map { .sticker($0) } ?? .card(card.kind), text: card.text, at: m.at))
            slot += 1
            // 歌卡下面它那句话是一个真气泡（09-30 Tilia：分开发，能引用——之前自用的 App那种引用不了）
            if let why = card.song?.why, !why.isEmpty, slot < bubbleSlot {
                out.append(ChatItem(id: rowID(message: m.id, slot: slot), messageID: m.id, mine: false, kind: .text,
                                    text: why, at: m.at))
                slot += 1
            }
        }
        let peeks = (m.cards ?? []).filter { $0.kind.hasPrefix("peek") }
        let room = slots - bubbleSlot - peeks.count
        if bubbles.count > room { bubbles = Array(bubbles.prefix(room - 1)) + [bubbles.dropFirst(room - 1).joined(separator: "\n\n")] }
        for (i, text) in bubbles.enumerated() {
            let v = (m.voices ?? []).indices.contains(i) ? m.voices?[i] : nil
            out.append(ChatItem(id: rowID(message: m.id, slot: bubbleSlot + i), messageID: m.id, mine: false, kind: .text,
                                text: text, at: m.at, reaction: i == bubbles.count - 1 ? m.reaction : nil, voice: v ?? nil))
        }
        // 查手机申请卡排在它说的话后面（先说，再递申请）
        for (j, card) in peeks.enumerated() {
            out.append(ChatItem(id: rowID(message: m.id, slot: bubbleSlot + bubbles.count + j), messageID: m.id, mine: false,
                                kind: .card(card.kind), text: card.text, at: m.at))
        }
        return out
    }
}

/// 一个窗口的聊天：接正式接口（server/api/routes_chat.py）。
///
/// - 进来拿最近 50 条（`before` 一个很大的号），上滑再往前翻。
/// - 发：气泡当场立起来（本机回显）→ `POST /messages {text, client_id}` 进等候区；
///   30 秒还没收到这一轮的任何事件就带同一个 client_id 重发（服务器认得，不会排两次）。
/// - 收：事件流 typing / thinking / card / bubble / error / notice / done，边推边画；
///   这一轮开始（第一个 typing）和结束（done）各补拉一次，把本机的行换成服务器的真身——同一次赋值里换，不闪。
/// - 切后台回来 / 事件流断了重连：补拉 + 重连。
@MainActor
final class ChatStore: ObservableObject {
    let api: APIClient
    let conversation: UUID
    /// 「回到那天」：只读回顾，从这条前后开始看，不连事件流、不能发
    let anchor: Int?

    @Published private(set) var items: [ChatItem] = []
    @Published var typing = false
    @Published private(set) var connected = false
    @Published var errorText: String?
    @Published private(set) var loadingOlder = false
    @Published private(set) var reachedHistoryStart = false
    @Published private(set) var loaded = false
    /// 回顾往下翻到头了（正常聊天永远在最新处）
    @Published private(set) var reachedEnd = true
    @Published private(set) var loadingNewer = false
    /// 照片 / 文件正在上传
    @Published private(set) var uploading = false

    /// 服务器的消息（按号从小到大），行都从它推出来
    private var messages: [MessageDTO] = []
    /// 还没被服务器确认的那几句
    private struct Echo {
        let id: Int
        let clientID: String
        let text: String
        var sentAt: Date
        var tries: Int
        var attachments: [AttachmentDTO] = []
    }
    private var echoes: [Echo] = []
    /// 这一轮正在推的（思考、卡片、气泡）；done 之后补拉到真身就清掉
    private var live: [ChatItem] = []
    private var liveDone = false
    private var localCounter = 0
    /// 最近一次收到事件的时刻：发出去之后这么久都没动静，就重发
    private var lastEventAt = Date.distantPast
    private var replyWait: Double = 10
    private var streamTask: Task<Void, Never>?

    /// TA 说了、它还没回完（灵动岛：这时候切走就挂「正在想」）
    var awaitingReply: Bool { !echoes.isEmpty || typing || (!live.isEmpty && !liveDone) }
    private var watchdog: Task<Void, Never>?

    static let pageSize = 50
    private var path: String { "conversations/\(conversation.uuidString.lowercased())" }

    init(api: APIClient, conversation: UUID, anchor: Int? = nil) {
        self.api = api
        self.conversation = conversation
        self.anchor = anchor
    }

    func start() {
        if let anchor {
            Task { await loadAround(anchor) }
            return
        }
        Task { await loadLatest() }
        startStream()
    }

    func stop() {
        streamTask?.cancel()
        watchdog?.cancel()
    }

    /// 从后台回到前台：补拉、重建事件流（后台挂起会弄死旧连接），还没确认的那几句再发一遍
    func resume() {
        guard anchor == nil else { return }
        Task {
            await catchUp()
            for echo in echoes { await post(echo) }
        }
        startStream()
    }

    private func nextLocalID() -> Int {
        localCounter += 1
        return ChatItem.localBase + localCounter
    }

    private func rebuild() {
        let echoRows = echoes.map { ChatItem(id: $0.id, messageID: nil, mine: true, kind: .text, text: $0.text, at: $0.sentAt,
                                             attachments: $0.attachments) }
        var server = messages.flatMap(ChatItem.rows(of:))
        if !aliases.isEmpty {
            for i in server.indices { if let a = aliases[server[i].id] { server[i].id = a } }
        }
        items = server + live + echoRows
    }

    /// 正式行号 → 当初临时那一行的号（10-01 Tilia：带卡片的那条说完不是平滑上去，是顿一下）。
    /// 这一轮推着的几行、TA 那句回显，换成服务器的真身时沿用原来的号：列表当成「同一行内容变了」，不删了再插。
    private var aliases: [Int: Int] = [:]

    /// 它这一轮推着的几行 ↔ 真身的几行，按顺序对：思考对思考，其余同种的按先后对上
    private func adopt(live: [ChatItem], for m: MessageDTO) {
        let real = ChatItem.rows(of: m)
        func sameKind(_ a: ChatItem.Kind, _ b: ChatItem.Kind) -> Bool {
            switch (a, b) {
            case (.text, .text), (.thinking, .thinking), (.card, .card), (.song, .song), (.sticker, .sticker): return true
            default: return false
            }
        }
        var pending = live.filter { !($0.kind == .thinking && $0.text.isEmpty) }
        for r in real {
            if let i = pending.firstIndex(where: { sameKind($0.kind, r.kind) }) {
                aliases[r.id] = pending[i].id
                pending.removeSubrange(0...i)          // 顺序只往前走，不回头配
            }
        }
    }

    // MARK: - 历史

    private func loadLatest() async {
        do {
            let page: MessagesPage = try await api.call("GET", "\(path)/messages", query: [
                URLQueryItem(name: "before", value: String(Int64(1) << 62)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ])
            merge(page.messages)
            reachedHistoryStart = !(page.hasMore ?? false)
            if page.busy { typing = true }
            loaded = true
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 回顾：锚点前后各一段（锚点本身在前一段里）
    private func loadAround(_ anchor: Int) async {
        do {
            let older: MessagesPage = try await api.call("GET", "\(path)/messages", query: [
                URLQueryItem(name: "before", value: String(anchor + 1)),
                URLQueryItem(name: "limit", value: "40"),
            ])
            let newer: MessagesPage = try await api.call("GET", "\(path)/messages", query: [
                URLQueryItem(name: "after", value: String(anchor)),
                URLQueryItem(name: "limit", value: "40"),
            ])
            merge(older.messages + newer.messages)
            reachedHistoryStart = !(older.hasMore ?? false)
            reachedEnd = newer.messages.isEmpty
            loaded = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 回顾往下翻一页（服务器会滤掉〔醒来〕，不满一页不代表到头——一条都没有才算）
    func loadNewer() async {
        guard !loadingNewer, !reachedEnd, let newest = messages.last?.id else { return }
        loadingNewer = true
        defer { loadingNewer = false }
        do {
            let page: MessagesPage = try await api.call("GET", "\(path)/messages", query: [
                URLQueryItem(name: "after", value: String(newest)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ])
            if page.messages.isEmpty { reachedEnd = true } else { merge(page.messages) }
        } catch {
            errorText = "后面的记录没拉下来，再试一次？"
        }
    }

    /// 按字搜（只搜说出口的话，不搜思考链），新的在前；网络失败返回 nil
    func search(_ q: String) async -> [SearchHit]? {
        struct Out: Decodable { let hits: [SearchHit] }
        let out: Out? = try? await api.call("GET", "\(path)/search", query: [URLQueryItem(name: "q", value: q),
                                                                           URLQueryItem(name: "limit", value: "100")])
        return out?.hits
    }

    /// 哪几天聊过
    func calendar() async -> [CalendarDay] {
        struct Out: Decodable { let days: [CalendarDay] }
        let out: Out? = try? await api.call("GET", "\(path)/calendar")
        return out?.days ?? []
    }

    /// 往上翻一页
    func loadOlder() async {
        guard !loadingOlder, !reachedHistoryStart, let oldest = messages.first?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page: MessagesPage = try await api.call("GET", "\(path)/messages", query: [
                URLQueryItem(name: "before", value: String(oldest)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ])
            merge(page.messages)
            reachedHistoryStart = !(page.hasMore ?? false)
        } catch {
            errorText = "更早的记录没拉下来，再试一次？"
        }
    }

    /// 补拉：比手上最新的那条还新的
    func catchUp() async {
        guard loaded else { await loadLatest(); return }
        do {
            let page: MessagesPage = try await api.call("GET", "\(path)/messages", query: [
                URLQueryItem(name: "after", value: String(messages.last?.id ?? 0)),
            ])
            merge(page.messages)
            if !page.busy, !live.isEmpty, liveDone { live = []; liveDone = false; rebuild() }
            if !page.busy { dropEmptyThinking() }     // 断线没等到 done：占位的「正在想」别一直挂着
        } catch {
            // 网络不好：等下一次事件或回前台再补
        }
    }

    private func merge(_ incoming: [MessageDTO]) {
        let known = Set(messages.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages = (messages + fresh).sorted { $0.id < $1.id }
        // 真身回来了就把对应的回显撤掉：一条真身里的每一句只销一条回显（她连发两句一样的「好～」时不会一起抹掉）
        for m in fresh where m.role == "user" {
            for (slot, part) in (m.bubbles ?? [m.text]).enumerated() {
                if let i = echoes.firstIndex(where: { $0.text == part }) {
                    aliases[ChatItem.rowID(message: m.id, slot: slot)] = echoes[i].id
                    echoes.remove(at: i)
                }
            }
        }
        // 它那一轮的真身到了：推着的那几行换成真身（沿用它们的行号）
        if liveDone, let real = fresh.last(where: { $0.role == "assistant" }) {
            adopt(live: live, for: real)
            live = []
            liveDone = false
        }
        rebuild()
    }

    // MARK: - 发

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let echo = Echo(id: nextLocalID(), clientID: UUID().uuidString, text: trimmed, sentAt: Date(), tries: 0)
        echoes.append(echo)
        typing = true                    // 她一发出去对面就「正在输入」（之前自用的 App那样），不等服务器那十秒
        rebuild()
        ContextReporter.shared.reportMusicNow(onlyPlaying: true)   // 耳朵：在放歌就报一下放到哪（服务器等十秒才回，来得及）
        Task { await post(echo) }
        armWatchdog()
    }

    private func post(_ echo: Echo) async {
        struct Queued: Decodable { let queued: Bool; let reply_wait: Double? }
        do {
            var body: [String: Any] = ["text": echo.text, "client_id": echo.clientID]
            if !echo.attachments.isEmpty { body["attachments"] = echo.attachments.map { $0.id.uuidString.lowercased() } }
            let r: Queued = try await api.call("POST", "\(path)/messages", json: body)
            if let wait = r.reply_wait { replyWait = wait }
            errorText = nil
        } catch {
            errorText = "没发出去（\(error.localizedDescription)），会自己再试"
        }
    }

    /// 发照片 / 文件（可以带一句话）：先一个个传上去，图顺手塞进缓存（气泡秒出，不用再下载一遍），再跟平常一样发。
    /// files 里每一项：(数据, 文件名, mime)
    func sendAttachments(_ files: [(Data, String, String)], text: String = "") async {
        guard !files.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        var done: [AttachmentDTO] = []
        for (data, name, mime) in files {
            do {
                let att = try await api.upload("\(path)/attachments", fileName: name, mime: mime, data: data)
                if att.kind == "image" { AuthImageView.seed(urlPath: "attachments/\(att.id.uuidString.lowercased())", data: data) }
                done.append(att)
            } catch {
                errorText = "\(name) 没传上去：\(error.localizedDescription)"
            }
        }
        guard !done.isEmpty else { return }
        let echo = Echo(id: nextLocalID(), clientID: UUID().uuidString, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        sentAt: Date(), tries: 0, attachments: done)
        echoes.append(echo)
        typing = true
        rebuild()
        await post(echo)
        armWatchdog()
    }

    /// TA 发语音（10-03）：传上去 → 服务器转文字、量语气 → 照常发（正文 = 转写，语音挂成附件）
    func sendVoice(_ data: Data, seconds: Double) async {
        struct Out: Decodable { let attachment: AttachmentDTO; let text: String }
        uploading = true
        defer { uploading = false }
        do {
            let raw = try await api.multipartFields("POST", "\(path)/voice", fields: ["seconds": String(format: "%.1f", seconds)],
                                                    files: [("audio", "voice.m4a", "audio/mp4", data)])
            let out = try APIClient.decoder.decode(Out.self, from: raw)
            let echo = Echo(id: nextLocalID(), clientID: UUID().uuidString, text: out.text, sentAt: Date(), tries: 0,
                            attachments: [out.attachment])
            echoes.append(echo)
            typing = true
            rebuild()
            await post(echo)
            armWatchdog()
        } catch {
            errorText = (error as? APIError)?.message ?? "语音没发出去"
        }
    }

    /// 从表情包面板发一张（10-01）：服务器复制成这个窗口的附件，然后照发图那样发
    func sendSticker(_ id: Int) async {
        do {
            let att: AttachmentDTO = try await api.call("POST", "\(path)/stickers/\(id)")
            let echo = Echo(id: nextLocalID(), clientID: UUID().uuidString, text: "", sentAt: Date(), tries: 0, attachments: [att])
            echoes.append(echo)
            typing = true
            rebuild()
            await post(echo)
            armWatchdog()
        } catch {
            errorText = "表情包没发出去：\(error.localizedDescription)"
        }
    }

    /// 看门狗：还有没确认的话，而且等候时间 + 30 秒里一个事件都没来 → 同一个 client_id 重发，最多三次
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while let self, !Task.isCancelled, !self.echoes.isEmpty {
                try? await Task.sleep(for: .seconds(5))
                let quietSince = max(self.lastEventAt, self.echoes.map(\.sentAt).max() ?? .distantPast)
                guard Date().timeIntervalSince(quietSince) > self.replyWait + 30 else { continue }
                for i in self.echoes.indices where self.echoes[i].tries < 3 {
                    self.echoes[i].tries += 1
                    self.echoes[i].sentAt = Date()
                    await self.post(self.echoes[i])
                }
                if self.echoes.allSatisfy({ $0.tries >= 3 }) {
                    self.errorText = "服务器一直没回应，检查一下网络"
                    self.typing = false
                    return
                }
            }
        }
    }

    // MARK: - 查手机申请（Lite）

    /// 答它的查手机申请：卡上先改成「给看了 / 没给看」，再告诉小管家（失败改回来）
    func answerPeek(row: Int, messageID: Int?, allow: Bool, rooms: [String]) async {
        let kind = allow ? "peek:ok:" + rooms.joined(separator: ",") : "peek:no"
        func set(_ k: String) {
            if let mid = messageID, let i = messages.firstIndex(where: { $0.id == mid }),
               let ci = messages[i].cards?.lastIndex(where: { $0.kind.hasPrefix("peek") }) {
                messages[i].cards?[ci].kind = k
            } else if let i = live.firstIndex(where: { $0.id == row }) {
                live[i].kind = .card(k)
            }
            rebuild()
        }
        set(kind)
        do {
            try await api.send("POST", "conversations/\(conversation.uuidString.lowercased())/peek", json: ["allow": allow, "rooms": rooms])
        } catch {
            set("peek:ask")
            errorText = error.localizedDescription
        }
    }

    // MARK: - 标记表情、倒回

    /// 给它的一句点表情（一条一个，再点同一个 = 取消）。先在本地改，服务器失败再改回来。
    func react(messageID: Int, emoji: String) async {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), messages[i].role == "assistant" else { return }
        let old = messages[i].reaction
        let clearing = old == emoji
        messages[i].reaction = clearing ? nil : emoji
        rebuild()
        do {
            if clearing {
                try await api.send("DELETE", "messages/\(messageID)/reaction")
            } else {
                try await api.send("PUT", "messages/\(messageID)/reaction", json: ["emoji": emoji])
            }
        } catch {
            if let j = messages.firstIndex(where: { $0.id == messageID }) { messages[j].reaction = old; rebuild() }
            errorText = "表情没点上：\(error.localizedDescription)"
        }
    }

    /// 这条之后还有没有别的（倒回会连它们一起撤，要先问一声）
    func hasMessages(after messageID: Int) -> Bool {
        messages.contains { $0.id > messageID } || !echoes.isEmpty
    }

    /// 倒回。点 TA 的一句 = 这句和之后的全撤，返回原文（放回输入栏）；
    /// 点它的一轮 = 这轮回复（和之后的）撤掉，服务器接着重新回，事件照样从事件流来。
    func rewind(messageID: Int) async -> String? {
        struct Out: Decodable { let kind: String; let text: String? }
        do {
            let out: Out = try await api.call("POST", "\(path)/rewind", json: ["message_id": messageID])
            messages.removeAll { $0.id >= messageID }
            live = []
            liveDone = false
            if out.kind == "regenerate" { typing = true }
            rebuild()
            return out.text
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    // MARK: - 事件流

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.streamOnce()
                guard !Task.isCancelled else { break }
                self.connected = false
                try? await Task.sleep(for: .seconds(3))   // 断线重连
            }
        }
    }

    private func streamOnce() async {
        do {
            connected = true
            await catchUp()              // 每次（重）连上都补拉断线期间错过的
            for try await ev in api.events(conversation: conversation) {
                handle(ev)
            }
        } catch {
            // 掉线走外层重连
        }
    }

    private func handle(_ ev: ChatEvent) {
        lastEventAt = Date()
        switch ev.type {
        case "typing":
            if liveDone { live = []; liveDone = false; rebuild() }     // 上一轮的真身没补上：先收掉
            if live.isEmpty {
                Task { await catchUp() }                                // 这一轮刚开始（还没推出东西）：TA 那句已经存了，换成真身
                // 思考链先占好最上面那一行（10-01 Tilia：卡片先挂上、思考写完才到，插到最上面会把卡片挤下去，一跳一跳的）。
                // 思考到了填进这一行，谁都不挪；这一轮没有思考就在 done 时撤掉
                live.insert(ChatItem(id: nextLocalID(), messageID: nil, mine: false, kind: .thinking, text: "", at: Date()), at: 0)
                rebuild()
            }
            typing = true
        case "thinking":
            // 思考排在这一轮最前面（它先想，再动手，再说）——跟补拉回来的顺序一样；占位那一行在就填进去
            if let i = live.firstIndex(where: { $0.kind == .thinking && $0.text.isEmpty }) {
                live[i].text = ev.text ?? ""
                live[i].thinkingMs = ev.ms
            } else {
                live.insert(ChatItem(id: nextLocalID(), messageID: nil, mine: false, kind: .thinking,
                                     text: ev.text ?? "", at: Date(), thinkingMs: ev.ms), at: 0)
            }
            rebuild()
        case "relationship":             // 它改了你们的关系：不挂卡，名字旁边的图标换一下（09-29）
            NotificationCenter.default.post(name: .lumiRelationshipChanged, object: nil)
        case "card":
            guard ev.isPrivate != true else { return }
            if ev.song == nil, ev.stickerID == nil, ChatItem.isDeed(ev.kind ?? "") {
                // 并进这一轮的「做了几件事」：有就加一件，没有就在思考后面立一行
                let deed = ChatItem.Deed(kind: ev.kind ?? "", text: ev.text ?? "")
                if let i = live.firstIndex(where: { if case .deeds = $0.kind { true } else { false } }),
                   case .deeds(let list) = live[i].kind {
                    live[i].kind = .deeds(list + [deed])
                } else {
                    let at = live.firstIndex(where: { $0.kind != .thinking }) ?? live.count
                    live.insert(ChatItem(id: nextLocalID(), messageID: nil, mine: false, kind: .deeds([deed]), text: "", at: Date()), at: at)
                }
                rebuild()
                return
            }
            live.append(ChatItem(id: nextLocalID(), messageID: nil, mine: false,
                                 kind: ev.song.map { .song($0) } ?? ev.stickerID.map { .sticker($0) } ?? .card(ev.kind ?? ""), text: ev.text ?? "", at: Date()))
            if let why = ev.song?.why, !why.isEmpty {
                live.append(ChatItem(id: nextLocalID(), messageID: nil, mine: false, kind: .text, text: why, at: Date()))
            }
            if let song = ev.song, song.queue == true {   // 一起听页开着：排进「音乐」的播放队列
                NotificationCenter.default.post(name: .lumiSongQueued, object: nil, userInfo: ["song": song])
            }
            rebuild()
        case "bubble":
            live.append(ChatItem(id: nextLocalID(), messageID: nil, mine: false, kind: .text,
                                 text: ev.text ?? "", at: Date(), voice: ev.voice))
            typing = false               // 同一次刷新里：三个点直接换成正文
            rebuild()
        case "notice":
            errorText = ev.text
        case "error":
            errorText = ev.message ?? "出了点问题"
            typing = false
            dropEmptyThinking()
        case "done":
            typing = false
            liveDone = true
            dropEmptyThinking()
            Task { await catchUp() }
        default:
            break                        // recall / usage / injections / ledger：给测试台看的
        }
    }

    /// 这一轮没有思考（关了、或者它没想）：占位那一行撤掉
    private func dropEmptyThinking() {
        let before = live.count
        live.removeAll { $0.kind == .thinking && $0.text.isEmpty }
        if live.count != before { rebuild() }
    }

    // MARK: - 自测（-chatSelfTest）

    /// 往末尾塞一条只活在本机的它的话（自测看来消息的滚动），返回行号好撤掉
    func selfTestAppend(_ text: String) -> Int {
        let item = ChatItem(id: nextLocalID(), messageID: nil, mine: false, kind: .text, text: text, at: Date())
        live.append(item)
        rebuild()
        return item.id
    }

    func selfTestRemove(_ id: Int) {
        live.removeAll { $0.id == id }
        rebuild()
    }
}
