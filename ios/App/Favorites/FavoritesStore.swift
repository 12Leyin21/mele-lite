import Foundation

// MARK: - 收藏夹的数据（10-02，移植自之前自用的 App FavoritesStore；Mele 存服务器 server/api/routes_favorites.py）
//
// 一条收藏 = 一个气泡：消息号 + 槽位（跟聊天页的行号同一套：行号 = 消息号 × 64 + 槽位）。
// 多选收成一组的共用一个 groupID。原话整个存在服务器上，窗口删了、倒回了也还在。

extension Notification.Name {
    static let lumiOpenFavorites = Notification.Name("LumiOpenFavorites")
}

struct FavoriteDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let companionID: UUID
    let conversationID: UUID
    let messageID: Int
    let slot: Int
    let mine: Bool
    let text: String
    let files: [AttachmentDTO]
    let groupID: UUID?
    let saidAt: Date
    let savedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, slot, mine, text, files
        case companionID = "companion_id", conversationID = "conversation_id", messageID = "message_id"
        case groupID = "group_id", saidAt = "said_at", savedAt = "saved_at"
    }

    var rowID: Int { ChatItem.rowID(message: messageID, slot: slot) }
    var images: [AttachmentDTO] { files.filter { $0.kind == "image" } }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [FavoriteDTO] = []
    @Published private(set) var loaded = false
    /// 收着的气泡（行号），聊天页长按菜单查这个
    @Published private(set) var rows: Set<Int> = []

    func contains(_ rowID: Int) -> Bool { rows.contains(rowID) }

    func load(_ api: APIClient) async {
        guard let got: [FavoriteDTO] = try? await api.call("GET", "favorites") else { return }
        set(got)
        loaded = true
    }

    func loadIfNeeded(_ api: APIClient) async {
        if !loaded { await load(api) }
    }

    /// 聊天里长按：收 / 取消
    func toggle(_ item: ChatItem, api: APIClient) async {
        guard let mid = item.messageID else { return }
        let slot = item.id - ChatItem.rowID(message: mid, slot: 0)
        if contains(item.id) {
            rows.remove(item.id)
            items.removeAll { $0.rowID == item.id }
            _ = try? await api.raw("DELETE", "favorites/bubble/\(mid)/\(slot)")
        } else {
            rows.insert(item.id)
            await add([item], group: false, api: api)
        }
    }

    /// 多选：一段对话收成一组
    func addGroup(_ picked: [ChatItem], api: APIClient) async {
        await add(picked, group: picked.count > 1, api: api)
    }

    private func add(_ picked: [ChatItem], group: Bool, api: APIClient) async {
        let body: [[String: Any]] = picked.compactMap { item in
            guard let mid = item.messageID else { return nil }
            return ["message_id": mid, "slot": item.id - ChatItem.rowID(message: mid, slot: 0),
                    "text": item.text, "with_files": !item.attachments.isEmpty]
        }
        guard !body.isEmpty else { return }
        if let got: [FavoriteDTO] = try? await api.call("POST", "favorites", json: ["items": body, "group": group]) {
            set(got + items)
        } else {
            await load(api)
        }
    }

    func remove(_ fav: FavoriteDTO, api: APIClient) async {
        set(items.filter { $0.id != fav.id })
        _ = try? await api.raw("DELETE", "favorites/\(fav.id)")
    }

    func removeGroup(_ gid: UUID, api: APIClient) async {
        set(items.filter { $0.groupID != gid })
        _ = try? await api.raw("DELETE", "favorites/group/\(gid.uuidString.lowercased())")
    }

    private func set(_ list: [FavoriteDTO]) {
        items = list.sorted { ($0.savedAt, $1.messageID, $1.slot) > ($1.savedAt, $0.messageID, $0.slot) }
        rows = Set(list.map(\.rowID))
    }

    /// 把同组（多选收藏）的折成块；组内按说话顺序
    static func blocks(_ items: [FavoriteDTO]) -> [[FavoriteDTO]] {
        var result: [[FavoriteDTO]] = []
        for item in items {
            if let gid = item.groupID, let last = result.last?.first?.groupID, gid == last {
                result[result.count - 1].append(item)
            } else {
                result.append([item])
            }
        }
        return result.map { $0.count > 1 ? $0.sorted { ($0.messageID, $0.slot) < ($1.messageID, $1.slot) } : $0 }
    }
}
