import SwiftUI

/// 水位（Lite，10-04 Tilia）：聊天页左下角一小行。数是上一轮实际喂给模型的 token；
/// 「还剩多少满」= 离记性长度还差多少——满了回声就把旧的卷进账本。
struct GaugeLine: View {
    let api: APIClient
    let conversation: UUID
    let tick: Bool               // 它说完（typing 变 false）就重读
    let skin: ChatSkin
    @State private var text = ""

    var body: some View {
        HStack {
            Text(text).font(Typo.number(skin.size(Typo.Size.caption), .regular)).foregroundStyle(skin.inkFaint)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 2)
        .opacity(text.isEmpty ? 0 : 1)
        .task(id: tick) { if !tick { await load() } }
    }

    private func load() async {
        guard let g = try? await api.raw("GET", "conversations/\(conversation.uuidString.lowercased())/gauge") as? [String: Any],
              g["known"] as? Bool == true, let tokens = g["tokens"] as? Int else { return }
        let left = g["remaining"] as? Int ?? 0
        text = g["full"] as? Bool == true
            ? String(localized: "当前 \(Self.k(tokens)) tokens · 满了，正在卷进回声")
            : String(localized: "当前 \(Self.k(tokens)) tokens · 还剩约 \(Self.k(left)) 满")
    }

    static func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

/// 用量（Lite，10-04 Tilia）：按天、按模型——几次、输入、命中缓存几成、输出、大概花了多少
struct UsageView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme

    private struct Row: Identifiable {
        let id = UUID()
        let model: String
        let calls, input, cacheRead, cacheWrite, output: Int
        let cost: Double?
        var prompt: Int { input + cacheRead + cacheWrite }
        var hit: Double { prompt > 0 ? Double(cacheRead) / Double(prompt) : 0 }
    }
    private struct Day: Identifiable {
        let day: String
        let rows: [Row]
        var id: String { day }
        var cost: Double? { rows.contains { $0.cost == nil } && rows.allSatisfy { $0.cost == nil } ? nil : rows.compactMap(\.cost).reduce(0, +) }
    }
    @State private var days: [Day] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("用了多少").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                Text("每次 TA 回你、写日记、解塔罗……用的都是你自己的 key，这里按天记着。「命中缓存」越高越省；钱是照价目表估的，以模型公司的账单为准。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                if loaded && days.isEmpty {
                    Text("还没有记录。聊几句再来看。").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).padding(.top, 20)
                }
                ForEach(days) { d in dayCard(d) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle("用量")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func dayCard(_ d: Day) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(d.day == today ? String(localized: "今天") : d.day).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Spacer()
                if let c = d.cost { Text(Self.money(c)).font(Typo.number(Typo.Size.headline, .semibold)).foregroundStyle(theme.accentDeep) }
            }
            ForEach(d.rows) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.model).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                        Spacer()
                        if let c = r.cost { Text(Self.money(c)).font(Typo.number(Typo.Size.callout)).foregroundStyle(theme.inkDim) }
                    }
                    Text("\(r.calls) 次 · 输入 \(GaugeLine.k(r.prompt)) · 输出 \(GaugeLine.k(r.output))")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.accentSoft.opacity(0.35))
                                Capsule().fill(theme.accent).frame(width: geo.size.width * r.hit)
                            }
                        }
                        .frame(height: 6)
                        Text("命中缓存 \(Int((r.hit * 100).rounded()))%").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.accentDeep)
                            .fixedSize()
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.6)))
    }

    private var today: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    static func money(_ v: Double) -> String { v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }

    private func load() async {
        defer { loaded = true }
        guard let raw = try? await model.api.raw("GET", "usage") as? [[String: Any]] else { return }
        days = raw.map { d in
            Day(day: d["day"] as? String ?? "", rows: (d["models"] as? [[String: Any]] ?? []).map { r in
                Row(model: r["model"] as? String ?? "", calls: r["calls"] as? Int ?? 0, input: r["input"] as? Int ?? 0,
                    cacheRead: r["cache_read"] as? Int ?? 0, cacheWrite: r["cache_write"] as? Int ?? 0, output: r["output"] as? Int ?? 0,
                    cost: r["cost"] as? Double)
            })
        }
    }
}

/// Me 里那一行
struct UsageCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        NavigationLink {
            UsageView().environmentObject(model).environmentObject(theme)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(Typo.icon(16)).foregroundStyle(theme.accentDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("用量").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                    Text("每天用了多少、命中缓存几成、大概花了多少").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
            }
            .padding(16)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
