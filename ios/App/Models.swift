import Foundation

/// 服务器回来的东西（字段名跟 server/api/ 一一对应）。

struct AccountDTO: Decodable {
    let id: UUID
    let email: String?
    let plan: String
    /// 免费额度（09-28 起按 token 折成钱算）：只给比例和下次补的时间；有自己 key 的也照样有
    let trial: TrialDTO?
}

struct TrialDTO: Decodable {
    let ratio: Double
    let refillAt: Date
    enum CodingKeys: String, CodingKey { case ratio; case refillAt = "refill_at" }
}

struct LoginDTO: Decodable {
    let token: String
    let account: AccountDTO
}

struct CompanionDTO: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    /// 头像版本号：0 = 没传过（显示首字母圆）；手机按「编号 + 版本」缓存
    var avatarVer: Int = 0
    var createdAt: Date?
    /// 最近 7 天聊了几句（首页「最常聊」）
    var weekMessages: Int = 0
    /// 一共聊了几句（首页「认识第几天」中号、大号，10-04）
    var totalMessages: Int = 0
    /// 用哪把钥匙；nil = 免费额度
    var keyID: String?
    /// 你们是什么关系（friend / partner / family / buddy / 自己写的；空 = 没说）：聊天页名字旁边的小图标
    var relationship: String = ""
    enum CodingKeys: String, CodingKey {
        case id, name; case avatarVer = "avatar_ver"; case createdAt = "created_at"; case weekMessages = "week_messages"
        case totalMessages = "total_messages"
        case keyID = "key_id"; case relationship
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatarVer = try c.decodeIfPresent(Int.self, forKey: .avatarVer) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        weekMessages = try c.decodeIfPresent(Int.self, forKey: .weekMessages) ?? 0
        totalMessages = try c.decodeIfPresent(Int.self, forKey: .totalMessages) ?? 0
        keyID = try c.decodeIfPresent(String.self, forKey: .keyID)
        relationship = try c.decodeIfPresent(String.self, forKey: .relationship) ?? ""
    }
}

struct ConversationDTO: Decodable, Identifiable, Hashable {
    let id: UUID
    let incognito: Bool
    let lastAt: Date
    let preview: String
    /// 窗口名：空 = 用第一句（first）
    var title: String = ""
    var first: String = ""
    /// 小号窗口（Lite，10-04）：TA 在这个窗口里把你当成的那个人叫什么；空 = 平常的你
    var altName: String = ""
    enum CodingKeys: String, CodingKey { case id, incognito, preview, title, first, alt; case lastAt = "last_at" }
    /// 小号窗口属于哪个小号（rooms/alts.json 的 id）
    var altID: String = ""
    private struct Alt: Decodable { let id: String?; let user_name: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        incognito = try c.decode(Bool.self, forKey: .incognito)
        lastAt = try c.decode(Date.self, forKey: .lastAt)
        preview = try c.decode(String.self, forKey: .preview)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        first = try c.decodeIfPresent(String.self, forKey: .first) ?? ""
        let alt = try? c.decodeIfPresent(Alt.self, forKey: .alt)
        altName = alt?.user_name ?? ""
        altID = alt?.id ?? ""
    }

    /// 列表里显示的名字
    var displayName: String {
        if !title.isEmpty { return title }
        if !altName.isEmpty { return String(localized: "小号 · \(altName)") }
        return !first.isEmpty ? first : String(localized: "新窗口")
    }
}

/// 我的设定（账号级）：名字、怎么称呼我、外貌
struct ProfileDTO: Codable, Equatable {
    var name: String
    var pronoun: String         // she / he / they
    var looks: String
}

struct AttachmentDTO: Decodable, Identifiable, Hashable {
    let id: UUID
    let kind: String            // image / file / voice（10-03 TA 的语音）
    let name: String
    let mime: String
    let size: Int
    var seconds: Int?           // 语音才有
}

struct CardDTO: Decodable, Hashable {
    var kind: String            // remember / search / manual / clock / error / song …
    let text: String
    /// 歌卡的歌（09-30）；别的卡的 data 形状不一样，解不出来就当没有
    var song: SongCardData?
    /// 表情包卡（10-01）：data = {sticker_id}
    var stickerID: Int?

    enum CodingKeys: String, CodingKey { case kind, text, data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        song = kind == "song" ? try? c.decodeIfPresent(SongCardData.self, forKey: .data) : nil
        stickerID = kind == "sticker" ? (try? c.decodeIfPresent(StickerRef.self, forKey: .data))?.stickerID : nil
        if kind == "peek" { kind = PeekState.kind(try? c.decodeIfPresent(PeekState.self, forKey: .data)) }
    }
}

/// 它申请翻手机的卡（Lite，10-04）：data = {state: ask / ok / no, rooms}；进 ChatItem 时写成 kind「peek:ask」「peek:ok:diary,wallet」
struct PeekState: Decodable {
    let state: String
    var rooms: [String]? = nil
    static func kind(_ s: PeekState?) -> String {
        guard let s else { return "peek:ask" }
        return s.state == "ok" ? "peek:ok:" + (s.rooms ?? []).joined(separator: ",") : "peek:" + s.state
    }
}

/// 表情包卡的 data
struct StickerRef: Decodable, Hashable {
    let stickerID: Int
    enum CodingKeys: String, CodingKey { case stickerID = "sticker_id" }
}

/// 歌卡上的一首歌（服务器 music 工具挂的卡 data）
struct SongCardData: Decodable, Hashable {
    let id: String
    let name: String
    let artist: String
    var artwork: String?
    var preview: String?
    var url: String?
    var why: String?
    /// 一起听页开着时它点的：手机直接排进「音乐」的播放队列
    var queue: Bool?
    var pick_day: String?
    var pos: Int?
}

struct MessageDTO: Decodable, Identifiable {
    let id: Int
    let role: String            // user / assistant
    let text: String
    let thinking: String
    let at: Date
    /// 服务器切好的气泡：它的话跟事件流里推的一样切；TA 连发的几句还原成几个
    var bubbles: [String]?
    /// 这一轮挂出来的动作卡片（只有它说的话才有）
    var cards: [CardDTO]?
    var reaction: String?
    var attachments: [AttachmentDTO]?
    /// 跟 bubbles 并排：那一泡是语音条就有（10-03），文字是 null
    var voices: [VoiceRef?]?
    /// 这一轮想了多久（毫秒，10-05）；早先的消息没有
    var thinkingMs: Int?
    enum CodingKeys: String, CodingKey {
        case id, role, text, thinking, at, bubbles, cards, reaction, attachments, voices
        case thinkingMs = "thinking_ms"
    }
}

struct MessagesPage: Decodable {
    let messages: [MessageDTO]
    let busy: Bool
    let hasMore: Bool?
    enum CodingKeys: String, CodingKey { case messages, busy; case hasMore = "has_more" }
}

/// 事件流里的一条：typing / thinking / card / bubble / error / notice / done（recall、usage、injections 这里不用）。
struct ChatEvent: Decodable {
    let type: String
    let text: String?
    var kind: String?
    let message: String?
    let isPrivate: Bool?
    var song: SongCardData?
    var stickerID: Int?
    var voice: VoiceRef?
    var ms: Int?                 // thinking：这一轮想了多久（10-05）
    enum CodingKeys: String, CodingKey { case type, text, kind, message, data, voice, ms; case isPrivate = "private" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate)
        song = kind == "song" ? try? c.decodeIfPresent(SongCardData.self, forKey: .data) : nil
        stickerID = kind == "sticker" ? (try? c.decodeIfPresent(StickerRef.self, forKey: .data))?.stickerID : nil
        voice = try? c.decodeIfPresent(VoiceRef.self, forKey: .voice)
        ms = try? c.decodeIfPresent(Int.self, forKey: .ms)
        if kind == "peek" { kind = PeekState.kind(try? c.decodeIfPresent(PeekState.self, forKey: .data)) }
    }
}

/// 搜索命中的一条，带前后各一条当上下文
struct SearchHit: Decodable, Identifiable {
    let message: MessageDTO
    let before: MessageDTO?
    let after: MessageDTO?
    var id: Int { message.id }
}

/// 聊天日历的一天
struct CalendarDay: Decodable, Identifiable {
    let day: String            // "2026-09-28"（联系人时区）
    let count: Int
    let firstID: Int
    var id: String { day }
    enum CodingKeys: String, CodingKey { case day, count; case firstID = "first_id" }
}

/// 联系人的设置里 app 用得到的几项
struct CompanionDetail: Decodable {
    struct SettingsPart: Decodable {
        let longMode: Bool?
        enum CodingKeys: String, CodingKey { case longMode = "long_mode" }
    }
    let id: UUID
    let name: String
    let settings: SettingsPart?
}

/// 醒来账（/companions/{id}/wakes）：首页「今天来找过你」和自唤醒页
struct WakesDTO: Decodable {
    struct Today: Decodable { let woke: Int; let said: Int; let costUsd: Double
        enum CodingKeys: String, CodingKey { case woke, said; case costUsd = "cost_usd" } }
    struct Item: Decodable, Identifiable, Hashable {
        let at: Date
        let reason: String          // whim / night_awake / asleep / user / self
        let outcome: String         // said / silent / skipped_* / error / no_key
        let messageID: Int?
        let text: String?
        let conversationID: UUID?
        var id: String { "\(at.timeIntervalSince1970)-\(reason)-\(outcome)" }
        enum CodingKeys: String, CodingKey {
            case at, reason, outcome, text; case messageID = "message_id"; case conversationID = "conversation_id"
        }
    }
    let today: Today
    let items: [Item]
    let silentByDay: [String: Int]
    enum CodingKeys: String, CodingKey { case today, items; case silentByDay = "silent_by_day" }
}
