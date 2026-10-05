import SwiftUI

// MARK: - 塔罗的数据和接口（10-03，服务器 server/api/routes_tarot.py；设计 docs/specs/2026-10-03-tarot-design.md）
//
// 牌阵、牌名、关键词全从服务器取，手机不写死（之前自用的 App那版要三处对齐，Mele 不这样）。
// 洗牌：服务器拿 TA 手搓的指尖轨迹 + 自己的真随机定种子，返回整副牌序；手机只交「第几张」。

extension Notification.Name {
    static let lumiOpenTarot = Notification.Name("LumiOpenTarot")
}

struct TarotSpreadDTO: Decodable, Identifiable, Hashable {
    let key: String
    let name: String
    let usage: String
    let count: Int
    let positions: [String]
    let layout: [[Double]]
    let boardHeight: CGFloat
    let cardWidth: CGFloat
    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name, usage, count, positions, layout
        case boardHeight = "board_height", cardWidth = "card_width"
    }

    func point(_ i: Int) -> CGPoint { CGPoint(x: layout[i][0], y: layout[i][1]) }

    /// 「再问一张」：一张，牌位叫「追问」（服务器那边同名，牌位以服务器存的为准）
    static let followup = TarotSpreadDTO(key: "followup", name: String(localized: "再问一张"),
                                         usage: String(localized: "接着这一局再问一句，再抽一张"), count: 1,
                                         positions: [String(localized: "追问")], layout: [[0.5, 0.5]],
                                         boardHeight: 190, cardWidth: 104)
}

struct TarotDeckCardDTO: Decodable, Hashable {
    let card: String
    let reversed: Bool
}

struct TarotDeckDTO: Decodable {
    let deckID: Int
    let deck: [TarotDeckCardDTO]
    enum CodingKeys: String, CodingKey { case deckID = "deck_id", deck }
}

struct TarotCardDTO: Decodable, Hashable {
    let position: String
    let card: String
    let reversed: Bool
    var name: String = ""
    var keywords: [String] = []

    enum CodingKeys: String, CodingKey { case position, card, reversed, name, keywords }
}

extension TarotCardDTO {
    init(position: String, card: String, reversed: Bool) {
        self.position = position; self.card = card; self.reversed = reversed
    }
}

struct TarotFollowupDTO: Decodable, Hashable {
    let question: String
    let card: TarotCardDTO
    let mode: String
    let interpretation: String
    let status: String
    let ts: String
}

struct TarotReadingDTO: Decodable, Identifiable, Hashable {
    let id: Int
    /// 谁来解：联系人编号；nil = 解牌人
    let reader: UUID?
    /// user = TA 问的 · contact = 它问自己的事
    let asker: String
    /// user = TA 自己抽 · contact = 它用工具抽的（替 TA 抽的也算）
    let drawnBy: String
    let question: String
    let spread: String
    let spreadName: String
    let mode: String
    let cards: [TarotCardDTO]
    let interpretation: String
    /// pending / asked / done / failed
    let status: String
    let followups: [TarotFollowupDTO]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, reader, asker, question, spread, mode, cards, interpretation, status, followups
        case drawnBy = "drawn_by", spreadName = "spread_name", createdAt = "created_at"
    }

    var isWaiting: Bool { status == "pending" || status == "asked" }
    var followupWaiting: Bool { followups.last.map { $0.status == "pending" || $0.status == "asked" } ?? false }
}

enum TarotAPI {
    static func spreads(_ api: APIClient) async throws -> [TarotSpreadDTO] {
        try await api.call("GET", "tarot/spreads")
    }

    static func deck(_ api: APIClient, trail: String) async throws -> TarotDeckDTO {
        try await api.call("POST", "tarot/deck", json: ["trail": trail])
    }

    static func save(_ api: APIClient, deck: Int, spread: String, question: String, reader: UUID?, from: UUID?,
                     picks: [Int], mode: String) async throws -> TarotReadingDTO {
        var body: [String: Any] = ["deck_id": deck, "spread": spread, "question": question, "picks": picks, "mode": mode,
                                   "reader": reader?.uuidString ?? NSNull()]
        if let from { body["from"] = from.uuidString }
        return try await api.call("POST", "tarot/readings", json: body)
    }

    static func followup(_ api: APIClient, id: Int, deck: Int, pick: Int, question: String,
                         mode: String) async throws -> TarotReadingDTO {
        try await api.call("POST", "tarot/readings/\(id)/followup",
                           json: ["deck_id": deck, "pick": pick, "question": question, "mode": mode])
    }

    static func list(_ api: APIClient) async throws -> [TarotReadingDTO] {
        try await api.call("GET", "tarot/readings")
    }

    static func one(_ api: APIClient, id: Int) async throws -> TarotReadingDTO {
        try await api.call("GET", "tarot/readings/\(id)")
    }

    static func retry(_ api: APIClient, id: Int) async throws -> TarotReadingDTO {
        try await api.call("POST", "tarot/readings/\(id)/retry")
    }

    static func delete(_ api: APIClient, id: Int) async throws {
        try await api.send("DELETE", "tarot/readings/\(id)")
    }
}

// MARK: - 深色 / 浅色（照之前自用的 App：塔罗深色比较神秘，默认深，右上角随时切，记住选择）

struct TarotStyle {
    let dark: Bool

    var ink: Color { dark ? .white.opacity(0.93) : AppTheme.ink }
    var inkDim: Color { dark ? .white.opacity(0.66) : AppTheme.inkDim }
    var inkFaint: Color { dark ? .white.opacity(0.42) : AppTheme.inkFaint }
    var chipFill: Color { dark ? .white.opacity(0.13) : Color.white.opacity(0.5) }
    var reversedTone: Color { dark ? Color(red: 0.93, green: 0.62, blue: 0.62)
                                   : Color(red: 0.72, green: 0.42, blue: 0.42) }
    var diagramStroke: Color { dark ? .white.opacity(0.65) : AppTheme.inkDim.opacity(0.7) }
    var diagramFill: Color { dark ? .white.opacity(0.14) : Color.white.opacity(0.55) }
}

/// 深色底：夜空 + 固定星点（不随帧闪，位置是确定性散布的）；浅色走全 App 同款背景
struct TarotBackground: View {
    let dark: Bool

    var body: some View {
        if dark {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.16),
                                            Color(red: 0.10, green: 0.11, blue: 0.27),
                                            Color(red: 0.05, green: 0.04, blue: 0.13)],
                                   startPoint: .top, endPoint: .bottom)
                    Canvas { context, size in
                        for i in 0..<90 {
                            let fx = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                            let fy = abs(sin(Double(i) * 78.233) * 12543.1234).truncatingRemainder(dividingBy: 1)
                            let r = 0.5 + Double(i % 3) * 0.5
                            let alpha = 0.12 + Double((i * 7) % 10) * 0.045
                            context.fill(Path(ellipseIn: CGRect(x: fx * size.width, y: fy * size.height, width: r, height: r)),
                                         with: .color(.white.opacity(alpha)))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
        } else {
            AppBackground()
        }
    }
}

/// 塔罗专用玻璃卡：深色时是夜里的毛玻璃，浅色时和全 App 同款
struct TarotGlass<Content: View>: View {
    @EnvironmentObject var theme: AppTheme
    let style: TarotStyle
    var padding: CGFloat = 15
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if style.dark {
                    ZStack {
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous).fill(Color.white.opacity(0.065))
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                            .fill(Color(red: 0.35, green: 0.38, blue: 0.75).opacity(0.10))
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous).fill(theme.accentSoft.opacity(0.13))
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous).stroke(Color.white.opacity(0.45), lineWidth: 1)
                    }
                }
            }
    }
}

/// 关键词小标签
struct TarotChips: View {
    let words: [String]
    let style: TarotStyle
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(words, id: \.self) { word in
                Text(word)
                    .font(.system(size: compact ? 9.5 : 11.5))
                    .padding(.horizontal, compact ? 7 : 10)
                    .padding(.vertical, compact ? 3 : 5)
                    .background(Capsule().fill(style.chipFill))
                    .foregroundStyle(style.inkDim)
                    .lineLimit(1)
            }
        }
    }
}

enum TarotWhen {
    static func format(_ date: Date) -> String {
        let out = DateFormatter()
        out.locale = Locale.current
        out.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "HH:mm" : "MMMd HH:mm")
        return Calendar.current.isDateInToday(date) ? String(localized: "今天 \(out.string(from: date))") : out.string(from: date)
    }

    static func dateOnly(_ date: Date) -> String {
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd"
        return out.string(from: date)
    }
}

/// 谁来解（联系人名字 / 解牌人）
enum TarotReader {
    static func name(_ id: UUID?, in companions: [CompanionDTO]) -> String {
        guard let id else { return String(localized: "解牌人") }
        return companions.first { $0.id == id }?.name ?? String(localized: "它")
    }
}
