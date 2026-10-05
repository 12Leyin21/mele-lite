import Foundation

/// 给模型的固定文字和给用户的提示都有中英两份。
public enum Lang: String, Codable, Sendable { case zh, en }

public enum Role: String, Codable, Sendable { case user, assistant }

/// 线上 = 日常短句；线下 = 长文（场景、动作、心理）。
public enum ChatMode: String, Codable, Sendable { case online, offline }

public enum ProviderKind: String, Codable, Sendable { case anthropic, openai, gemini }

public struct ProviderConfig: Codable, Equatable, Sendable {
    public var kind: ProviderKind
    /// 只有 OpenAI 兼容用得上：DeepSeek、OpenRouter 之类填自己的地址
    public var baseURL: String?
    public var model: String
    public var thinking: Bool

    public init(kind: ProviderKind, baseURL: String? = nil, model: String, thinking: Bool = false) {
        self.kind = kind; self.baseURL = baseURL; self.model = model; self.thinking = thinking
    }
}

/// 对面这个人在它眼里是谁。主号一个；小号可以有好几个，各自一份聊天，互相看不到。
public struct Identity: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var isMain: Bool
    public var userName: String
    public var aboutMe: String
    public var relationship: String

    public init(id: String = UUID().uuidString, isMain: Bool, userName: String, aboutMe: String = "", relationship: String = "") {
        self.id = id; self.isMain = isMain; self.userName = userName; self.aboutMe = aboutMe; self.relationship = relationship
    }
}

public struct Contact: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var avatarFile: String?
    public var persona: String
    public var mode: ChatMode
    public var provider: ProviderConfig
    public var identities: [Identity]

    public init(id: String = UUID().uuidString, name: String, avatarFile: String? = nil, persona: String,
                mode: ChatMode = .online, provider: ProviderConfig, userName: String = "") {
        self.id = id; self.name = name; self.avatarFile = avatarFile; self.persona = persona
        self.mode = mode; self.provider = provider
        self.identities = [Identity(isMain: true, userName: userName)]
    }

    public var mainIdentity: Identity { identities.first(where: \.isMain) ?? identities[0] }

    /// 小号：同一个人设，它把你当成另一个人，关系默认陌生人。
    @discardableResult
    public mutating func addAltIdentity(userName: String, aboutMe: String, lang: Lang = .zh) -> Identity {
        let alt = Identity(isMain: false, userName: userName, aboutMe: aboutMe,
                           relationship: lang == .zh ? "陌生人" : "stranger")
        identities.append(alt)
        return alt
    }
}

public struct Message: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var role: Role
    public var text: String
    public var thinking: String?
    public var quoteOf: String?
    public var stickerID: String?
    /// TA 发的照片：存在 root/images/ 下的文件名
    public var imageFile: String?
    public var at: Date

    public init(id: String = UUID().uuidString, role: Role, text: String, thinking: String? = nil,
                quoteOf: String? = nil, stickerID: String? = nil, imageFile: String? = nil, at: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.thinking = thinking
        self.quoteOf = quoteOf; self.stickerID = stickerID; self.imageFile = imageFile; self.at = at
    }
}

/// 收藏一条或一组；原消息删了收藏还在，所以文字整段存下来。
public struct Favorite: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var identityID: String
    public var messageIDs: [String]
    public var text: String
    public var at: Date

    public init(id: String = UUID().uuidString, contactID: String, identityID: String, messageIDs: [String], text: String, at: Date = Date()) {
        self.id = id; self.contactID = contactID; self.identityID = identityID
        self.messageIDs = messageIDs; self.text = text; self.at = at
    }
}

/// 世界书一条：说到关键词才递给它；常驻的每轮都递。contactIDs 为 nil = 给所有联系人。
public struct LoreEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var keys: [String]
    public var content: String
    public var contactIDs: [String]?
    public var constant: Bool
    public var enabled: Bool

    public init(id: String = UUID().uuidString, title: String, keys: [String], content: String,
                contactIDs: [String]? = nil, constant: Bool = false, enabled: Bool = true) {
        self.id = id; self.title = title; self.keys = keys; self.content = content
        self.contactIDs = contactIDs; self.constant = constant; self.enabled = enabled
    }
}

/// 表情包：同一张图（sha256 一样）只存一次、只让模型看一次；描述用户能改。
public struct Sticker: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sha: String
    public var file: String
    public var caption: String
    public var captionedAt: Date?

    public init(id: String = UUID().uuidString, sha: String, file: String, caption: String = "", captionedAt: Date? = nil) {
        self.id = id; self.sha = sha; self.file = file; self.caption = caption; self.captionedAt = captionedAt
    }
}

/// 查手机时 TA 给它看的那几间
public enum PeekRoom: String, Codable, CaseIterable, Sendable { case chats, lore, stickers, favorites }

/// 查手机记录：谁、哪个身份、看了哪几间、它说想看什么
public struct PeekLog: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var identityID: String
    public var rooms: [PeekRoom]
    public var asked: String
    public var at: Date

    public init(id: String = UUID().uuidString, contactID: String, identityID: String, rooms: [PeekRoom], asked: String, at: Date = Date()) {
        self.id = id; self.contactID = contactID; self.identityID = identityID; self.rooms = rooms; self.asked = asked; self.at = at
    }
}

/// 里程碑：聊天里它觉得值得记住就立一块
public struct Milestone: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var title: String
    public var at: Date

    public init(id: String = UUID().uuidString, contactID: String, title: String, at: Date = Date()) {
        self.id = id; self.contactID = contactID; self.title = title; self.at = at
    }
}

/// 它留给你的信：打开 App 时它可能写一封
public struct Letter: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var identityID: String
    public var title: String
    public var body: String
    public var locked: Bool
    public var at: Date

    public init(id: String = UUID().uuidString, contactID: String, identityID: String, title: String, body: String, locked: Bool = false, at: Date = Date()) {
        self.id = id; self.contactID = contactID; self.identityID = identityID; self.title = title; self.body = body; self.locked = locked; self.at = at
    }
}
