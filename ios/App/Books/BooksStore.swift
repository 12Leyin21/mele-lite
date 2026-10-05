import SwiftUI

// MARK: - 书架的数据（10-02，服务器 server/api/routes_books.py；设计 docs/specs/2026-10-02-bookshelf-design.md）

extension Notification.Name {
    static let lumiOpenBooks = Notification.Name("LumiOpenBooks")
}

struct BookDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let chapters: Int
    let atChapter: Int
    let atPage: Int
    let pageCount: Int
    let progress: Double
    let hasCover: Bool
    let todayMinutes: Int
    let marks: Int

    enum CodingKeys: String, CodingKey {
        case id, title, chapters, progress, marks
        case atChapter = "at_chapter", atPage = "at_page", pageCount = "page_count", hasCover = "has_cover"
        case todayMinutes = "today_minutes"
    }

    var coverPath: String { "books/\(id)/cover" }
}

struct ChapterDTO: Decodable, Identifiable, Hashable {
    let index: Int
    let title: String
    let length: Int
    var id: Int { index }
}

struct ChapterTextDTO: Decodable {
    let index: Int
    let title: String
    let text: String
}

struct BookMarkDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let bookID: Int
    let chapter: Int
    let quote: String
    let note: String
    let pos: Int
    let author: String              // "user" 或联系人编号
    let companionID: UUID?
    let parentID: Int?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, chapter, quote, note, pos, author
        case bookID = "book_id", companionID = "companion_id", parentID = "parent_id", createdAt = "created_at"
    }

    var mine: Bool { author == "user" }
    var authorID: UUID? { UUID(uuidString: author) }
}

@MainActor
final class BooksStore: ObservableObject {
    @Published private(set) var books: [BookDTO] = []
    @Published private(set) var loaded = false
    @Published var error: String?

    func load(_ api: APIClient) async {
        do {
            books = try await api.call("GET", "books")
            loaded = true
        } catch {
            self.error = "书架没拉下来：\(error.localizedDescription)"
        }
    }

    func add(name: String, data: Data, api: APIClient) async {
        do {
            _ = try await api.multipartFields("POST", "books", fields: [:], files: [("file", name, "text/plain", data)])
            await load(api)
        } catch {
            self.error = "没导进来：\(error.localizedDescription)"
        }
    }

    func rename(_ b: BookDTO, to title: String, api: APIClient) async {
        _ = try? await api.raw("PATCH", "books/\(b.id)", json: ["title": title])
        await load(api)
    }

    func setCover(_ b: BookDTO, data: Data, api: APIClient) async {
        _ = try? await api.multipartFields("PUT", "books/\(b.id)/cover", fields: [:], files: [("file", "cover.jpg", "image/jpeg", data)])
        AuthImageView.seed(urlPath: b.coverPath, data: data)     // 换了封面：本地缓存直接换成新的
        await load(api)
    }

    func delete(_ b: BookDTO, api: APIClient) async {
        _ = try? await api.raw("DELETE", "books/\(b.id)")
        await load(api)
    }
}
