import SwiftUI

// MARK: - 塔罗房间（10-03，Library → 塔罗，深链 mele://tarot；移植自之前自用的 App的房间排法）
//
// 今天问一句（单张）· 牌阵（九种摊开选）· 牌局列表（顶上胶囊按谁来解筛：全部 / 每个联系人 / 解牌人 / 它们问的）。
// 塔罗的一切不进聊天流：抽完存档，服务器后台让选中的那位解，写在牌局页上；联系人解的它下次聊天会记得。

struct TarotRoomView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss

    @AppStorage("tarotDark") private var tarotDark = true
    private var style: TarotStyle { TarotStyle(dark: tarotDark) }

    enum Filter: Hashable { case all, reader(UUID?), theirs }

    @State private var spreads: [TarotSpreadDTO] = []
    @State private var readings: [TarotReadingDTO] = []
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var asking: TarotSpreadDTO?
    @State private var showSpreads = false
    @State private var presented: TarotReadingDTO?
    @State private var loadError: String?

    private var shown: [TarotReadingDTO] {
        switch filter {
        case .all: return readings
        case .theirs: return readings.filter { $0.asker == "contact" }
        case .reader(let id): return readings.filter { $0.reader == id && $0.asker == "user" }
        }
    }

    var body: some View {
        ZStack {
            TarotBackground(dark: tarotDark)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    quickStart
                    spreadsTile
                    historySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 60)
            }
        }
        .task { await load() }
        .fullScreenCover(item: $asking) { spread in
            TarotAskView(spread: spread) { q, deck, picks, mode, reader in
                await save(spread: spread, question: q, deck: deck, picks: picks, mode: mode, reader: reader)
            }
            .environmentObject(model).environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showSpreads) {
            TarotSpreadPicker(spreads: spreads) { spread in
                showSpreads = false
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    asking = spread
                }
            }
            .environmentObject(theme)
        }
        .fullScreenCover(item: $presented) { reading in
            TarotReadingView(reading: reading)
                .environmentObject(model).environmentObject(theme)
                .onDisappear { Task { await load() } }
        }
    }

    private func load() async {
        do {
            if spreads.isEmpty { spreads = try await TarotAPI.spreads(model.api) }
            readings = try await TarotAPI.list(model.api)
            loadError = nil
        } catch {
            loadError = (error as? APIError)?.message ?? String(localized: "没连上服务器")
        }
        loaded = true
    }

    @MainActor
    private func save(spread: TarotSpreadDTO, question: String, deck: Int, picks: [Int], mode: String,
                      reader: UUID?) async -> Bool {
        let from = model.chat?.companion.id ?? model.recentCompanion?.id
        guard let r = try? await TarotAPI.save(model.api, deck: deck, spread: spread.key, question: question, reader: reader,
                                               from: from, picks: picks, mode: mode) else { return false }
        readings.insert(r, at: 0)
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            presented = r
        }
        return true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style.inkDim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                // 深/浅切换：月亮 = 去深色，太阳 = 回浅色
                Button {
                    withAnimation(.easeInOut(duration: 0.35)) { tarotDark.toggle() }
                } label: {
                    Image(systemName: tarotDark ? "sun.max" : "moon.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(style.inkDim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)
            Text("塔罗").font(Fonts.serif(26, .semibold)).foregroundStyle(style.ink)
            Text("牌是镜子，不是判决书")
                .font(.system(size: 12)).foregroundStyle(style.inkDim)
        }
        .padding(.bottom, 2)
    }

    /// 今天问一句：单张，也走抽牌页自己抽
    private var quickStart: some View {
        Button {
            if let single = spreads.first(where: { $0.key == "single" }) { asking = single }
        } label: {
            TarotGlass(style: style, padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(theme.accent))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("今天问一句").font(Fonts.serif(16, .semibold)).foregroundStyle(style.ink)
                        Text("一张牌，自己抽").font(.system(size: 11.5)).foregroundStyle(style.inkFaint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(style.inkFaint)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(spreads.isEmpty)
    }

    private var spreadsTile: some View {
        Button { showSpreads = true } label: {
            TarotGlass(style: style, padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 19)).foregroundStyle(style.dark ? theme.accentSoft : theme.accent)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("牌阵").font(Fonts.serif(16, .semibold)).foregroundStyle(style.ink)
                        Text("九种阵摊开选").font(.system(size: 11.5)).foregroundStyle(style.inkFaint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(style.inkFaint)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(spreads.isEmpty)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "全部"), .all)
                ForEach(model.companions) { c in chip(c.name, .reader(c.id)) }
                chip(String(localized: "解牌人"), .reader(nil))
                chip(String(localized: "它们问的"), .theirs)
            }
        }
    }

    private func chip(_ title: String, _ f: Filter) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { filter = f } } label: {
            Text(title)
                .font(.system(size: 12, weight: filter == f ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(filter == f ? theme.accent.opacity(style.dark ? 0.32 : 0.2) : style.chipFill))
                .foregroundStyle(filter == f ? (style.dark ? theme.accentSoft : theme.accent) : style.inkDim)
        }
        .buttonStyle(.plain)
    }

    private var historySection: some View {
        TarotGlass(style: style, padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                Text("问过的牌").font(Fonts.serif(15, .semibold)).foregroundStyle(style.ink)
                filters
                if let loadError {
                    Text(loadError).font(.system(size: 12)).foregroundStyle(style.reversedTone)
                } else if loaded && shown.isEmpty {
                    Text(filter == .theirs ? String(localized: "它们还没问过牌——有心事的时候会来的")
                                           : String(localized: "还没问过——上面写个问题抽一张试试"))
                        .font(.system(size: 12)).foregroundStyle(style.inkFaint)
                        .padding(.vertical, 8)
                }
                ForEach(shown) { r in
                    Button { presented = r } label: { row(r) }
                        .buttonStyle(.plain)
                    if r.id != shown.last?.id { Divider().opacity(style.dark ? 0.2 : 0.35) }
                }
            }
        }
    }

    private func row(_ r: TarotReadingDTO) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("「\(r.question)」")
                    .font(Fonts.body(13.5, .medium)).foregroundStyle(style.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(TarotWhen.format(r.createdAt)).font(.system(size: 10.5)).foregroundStyle(style.inkFaint)
                    Text(r.spreadName)
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(theme.accent.opacity(0.18)))
                        .foregroundStyle(style.dark ? theme.accentSoft : theme.accent)
                    Text(byline(r)).font(.system(size: 10)).foregroundStyle(style.inkDim).lineLimit(1)
                    if r.isWaiting {
                        Text("解读中…").font(.system(size: 9.5)).foregroundStyle(style.inkFaint)
                    } else if r.status == "failed" {
                        Text("没解成").font(.system(size: 9.5)).foregroundStyle(style.reversedTone)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(style.inkFaint)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func byline(_ r: TarotReadingDTO) -> String {
        let who = TarotReader.name(r.reader, in: model.companions)
        if r.asker == "contact" { return String(localized: "\(who) 问的") }
        if r.drawnBy == "contact" { return String(localized: "\(who) 帮你抽的") }
        return String(localized: "\(who) 解")
    }
}

// MARK: - 牌阵（示意图 → 抽牌页）

struct TarotSpreadPicker: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let spreads: [TarotSpreadDTO]
    let onPick: (TarotSpreadDTO) -> Void

    @AppStorage("tarotDark") private var tarotDark = true
    private var style: TarotStyle { TarotStyle(dark: tarotDark) }

    var body: some View {
        ZStack {
            TarotBackground(dark: tarotDark)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(style.inkDim)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("牌阵").font(Fonts.serif(17, .semibold)).foregroundStyle(style.ink)
                        Spacer()
                        Color.clear.frame(width: 17, height: 17)
                    }
                    .padding(.bottom, 8)
                    ForEach(spreads) { spread in
                        Button { onPick(spread) } label: {
                            TarotGlass(style: style, padding: 14) {
                                HStack(spacing: 14) {
                                    SpreadDiagram(spread: spread, style: style).frame(width: 86, height: 64)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(spread.name).font(Fonts.serif(16, .semibold)).foregroundStyle(style.ink)
                                            Text("\(spread.count) 张").font(.system(size: 10.5)).foregroundStyle(style.inkFaint)
                                        }
                                        Text(spread.usage)
                                            .font(.system(size: 11.5)).foregroundStyle(style.inkDim)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(style.inkFaint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 60)
            }
        }
    }
}
