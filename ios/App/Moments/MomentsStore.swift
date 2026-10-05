import SwiftUI

/// 朋友圈（10-01，移植自之前自用的 App 的 MomentsStore.swift）的数据层。
/// who：「user」= 你，否则是联系人编号（小写）。不进聊天、不推送——路过才看；它们到点来刷是服务器的巡逻在跑。

extension Notification.Name {
    static let lumiOpenMoments = Notification.Name("LumiOpenMoments")
}

struct MomentLikeDTO: Decodable, Hashable { let who: String; let name: String }

struct MomentCommentDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let author: String
    let name: String
    let content: String
    let replyTo: Int?
    let replyToName: String?
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, author, name, content
        case replyTo = "reply_to", replyToName = "reply_to_name", createdAt = "created_at"
    }
}

struct MomentDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let author: String
    let name: String
    let content: String
    let images: Int
    let createdAt: Date
    let likes: [MomentLikeDTO]
    let comments: [MomentCommentDTO]
    enum CodingKeys: String, CodingKey { case id, author, name, content, images, likes, comments; case createdAt = "created_at" }

    var imagePaths: [String] { (0..<images).map { "moments/\(id)/images/\($0)" } }
}

struct MomentActivityDTO: Decodable, Identifiable, Hashable {
    let kind: String
    let who: String
    let name: String
    let at: Date
    let momentId: Int
    let post: String?
    let content: String?
    enum CodingKeys: String, CodingKey { case kind, who, name, at, post, content; case momentId = "moment_id" }
    var id: String { "\(kind)-\(who)-\(at.timeIntervalSince1970)-\(momentId)" }
}

struct MomentProfileDTO: Decodable {
    let who: String
    let name: String
    let signature: String
    let hasCover: Bool
    enum CodingKeys: String, CodingKey { case who, name, signature; case hasCover = "has_cover" }
}

enum MomentsTime {
    /// 「刚刚 / 12分钟前 / 3小时前 / 昨天 14:02 / 9月20日」
    static func when(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return String(localized: "刚刚") }
        if s < 3600 { return String(localized: "\(Int(s / 60))分钟前") }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "\(Int(s / 3600))小时前") }
        if cal.isDateInYesterday(date) { return String(localized: "昨天 \(date.formatted(.dateTime.hour().minute()))") }
        return date.formatted(.dateTime.month().day())
    }
}

@MainActor
final class MomentsStore: ObservableObject {
    @Published var moments: [MomentDTO] = []
    @Published var profile: MomentProfileDTO?
    @Published var activity: [MomentActivityDTO] = []
    @Published var error: String?
    /// 封面换过就换个地址，图片缓存不会拿旧的
    @Published var coverVersion = UserDefaults.standard.integer(forKey: "momentsCoverVer")
    @AppStorage("momentsSeen") var seen: Double = 0

    let api: APIClient
    /// nil = 全部（你的封面）；否则是某个人的主页
    let who: String?

    init(api: APIClient, who: String?) {
        self.api = api
        self.who = who
    }

    var owner: String { who ?? "user" }
    var coverPath: String { "moments/profile/\(owner)/cover?v=\(coverVersion)" }

    func load() async {
        do {
            var q = [URLQueryItem(name: "limit", value: "40")]
            if let who { q.append(URLQueryItem(name: "who", value: who)) }
            moments = try await api.call("GET", "moments", query: q)
            profile = try? await api.call("GET", "moments/profile/\(owner)")
            error = nil
        } catch { self.error = error.localizedDescription }
        if who == nil { await loadActivity() }
    }

    func loadActivity() async {
        var q: [URLQueryItem] = []
        if seen > 0 { q.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seen)))) }
        struct Out: Decodable { let count: Int; let items: [MomentActivityDTO] }
        if let a: Out = try? await api.call("GET", "moments/activity", query: q) { activity = a.items }
    }

    func markSeen() {
        seen = Date().timeIntervalSince1970
        activity = []
    }

    private func replace(_ m: MomentDTO) {
        if let i = moments.firstIndex(where: { $0.id == m.id }) { moments[i] = m }
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work(); error = nil } catch { self.error = error.localizedDescription }
    }

    func post(_ text: String, images: [Data]) async -> Bool {
        var ok = false
        await run {
            let out = try await api.postMoment(text, images: images)
            let m = try APIClient.decoder.decode(MomentDTO.self, from: out)
            for (i, d) in images.enumerated() { AuthImageView.seed(urlPath: "moments/\(m.id)/images/\(i)", data: d) }
            moments.insert(m, at: 0)
            ok = true
        }
        return ok
    }

    func toggleLike(_ m: MomentDTO) async {
        let on = !m.likes.contains { $0.who == "user" }
        await run { replace(try await api.call("POST", "moments/\(m.id)/like", json: ["liked": on])) }
    }

    func comment(_ m: MomentDTO, _ text: String, replyTo: Int?) async {
        var body: [String: Any] = ["content": text]
        if let replyTo { body["reply_to"] = replyTo }
        await run { replace(try await api.call("POST", "moments/\(m.id)/comments", json: body)) }
    }

    func deleteComment(_ c: MomentCommentDTO) async {
        await run {
            try await api.send("DELETE", "moments/comments/\(c.id)")
            await load()
        }
    }

    func delete(_ m: MomentDTO) async {
        await run {
            try await api.send("DELETE", "moments/\(m.id)")
            moments.removeAll { $0.id == m.id }
        }
    }

    func setSignature(_ text: String) async {
        await run {
            let _: [String: String] = try await api.call("PUT", "moments/profile/user/signature", json: ["signature": text])
            profile = try? await api.call("GET", "moments/profile/\(owner)")
        }
    }

    func setCover(_ data: Data) async {
        await run {
            _ = try await api.uploadCover(owner, data: data)
            coverVersion += 1
            UserDefaults.standard.set(coverVersion, forKey: "momentsCoverVer")
            AuthImageView.seed(urlPath: coverPath, data: data)
            profile = try? await api.call("GET", "moments/profile/\(owner)")
        }
    }
}

extension APIClient {
    /// 发一条朋友圈：content + 好几张 files（multipart）
    func postMoment(_ text: String, images: [Data]) async throws -> Data {
        try await multipartFields("POST", "moments", fields: ["content": text],
                                  files: images.enumerated().map { ("files", "moment-\($0.offset).jpg", "image/jpeg", $0.element) })
    }

    func uploadCover(_ who: String, data: Data) async throws -> Data {
        try await multipartFields("PUT", "moments/profile/\(who)/cover", fields: [:], files: [("file", "cover.jpg", "image/jpeg", data)])
    }
}
