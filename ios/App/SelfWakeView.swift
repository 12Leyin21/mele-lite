import SwiftUI

/// 自唤醒（第二块第 8 步，照之前自用的 App SelfWakeView 的全览）：它自己醒来、开口找你的那些次。
/// 按天倒排，每条：几点 · 为什么醒 · 它说的原话（点开看全文、能去聊天里看那一条）；没开口的只按天计数。
struct SelfWakeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var avatars: AvatarStore
    @Environment(\.dismiss) private var dismiss
    @State var companionID: UUID
    @State private var data: WakesDTO?
    @State private var loading = true
    @State private var expanded: Set<String> = []
    @State private var moment: MomentOpen?

    struct MomentOpen: Identifiable { let conversation: UUID; let message: Int; var id: Int { message } }

    private var companion: CompanionDTO? { model.companion(companionID) }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if model.companions.count > 1 { picker }
                    stats
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .environment(\.colorScheme, .light)
        .task(id: companionID) { await load() }
        .fullScreenCover(item: $moment) { m in
            MomentRoom(companionID: companionID, conversation: m.conversation, anchor: m.message, api: session.api)
                .environmentObject(theme).environmentObject(avatars).environmentObject(session)
        }
    }

    private func load() async {
        loading = true
        data = try? await session.api.call("GET", "companions/\(companionID.lowercased)/wakes",
                                           query: [URLQueryItem(name: "days", value: "30")])
        loading = false
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(Typo.icon(17, .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Self-wake").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            Spacer()
        }
        .padding(.leading, -12)
        .padding(.top, 6)
    }

    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sortedCompanions) { c in
                    Button { companionID = c.id } label: {
                        HStack(spacing: 6) {
                            CompanionAvatar(companion: c, size: 22)
                            Text(c.name).font(Typo.sans(Typo.Size.callout, c.id == companionID ? .semibold : .regular))
                        }
                        .foregroundStyle(c.id == companionID ? theme.accentDeep : theme.inkDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(c.id == companionID ? 0.75 : 0.35)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            stat(data?.today.said ?? 0, String(localized: "今天找了你"))
            stat(data?.today.woke ?? 0, String(localized: "今天醒了"))
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "$%.3f", data?.today.costUsd ?? 0))
                    .font(Typo.number(Typo.Size.headline)).foregroundStyle(theme.ink)
                Text("今天花了").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Radii.bubble, strength: 0.9)
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(n)").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            Text(label).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radii.bubble, strength: 0.9)
    }

    // MARK: 时间线

    private var said: [WakesDTO.Item] { (data?.items ?? []).filter { $0.outcome == "said" } }

    /// 按天分（手机时区）：有开口的天，或者只有安静醒来的天
    private var days: [(day: String, rows: [WakesDTO.Item])] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var groups: [String: [WakesDTO.Item]] = [:]
        for i in said { groups[f.string(from: i.at), default: []].append(i) }
        for d in (data?.silentByDay ?? [:]).keys where groups[d] == nil { groups[d] = [] }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    @ViewBuilder private var content: some View {
        if loading && data == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
        } else if days.isEmpty {
            Text("\(companion?.name ?? "TA") 还没自己醒过来找你。")
                .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkFaint)
                .frame(maxWidth: .infinity).padding(.vertical, 30)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(days, id: \.day) { g in daySection(g.day, g.rows) }
            }
        }
    }

    private func dayTitle(_ day: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return String(localized: "今天") }
        if Calendar.current.isDateInYesterday(d) { return String(localized: "昨天") }
        let g = DateFormatter(); g.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return g.string(from: d)
    }

    private func daySection(_ day: String, _ rows: [WakesDTO.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dayTitle(day)).font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                .padding(.bottom, 10)
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, e in
                row(e, last: idx == rows.count - 1)
            }
            if let n = data?.silentByDay[day], n > 0 {
                Text(String(localized: "另外安静醒了 \(n) 次"))
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    .padding(.top, rows.isEmpty ? 0 : 10).padding(.leading, rows.isEmpty ? 0 : 58)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func reasonLabel(_ r: String) -> String {
        switch r {
        case "user": return String(localized: "你定的钟")
        case "self": return String(localized: "它自己约的")
        case "night_awake": return String(localized: "深夜你还醒着")
        case "asleep": return String(localized: "你睡着的时候")
        default: return String(localized: "想到你了")
        }
    }

    private func row(_ e: WakesDTO.Item, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(e.at, format: .dateTime.hour().minute())
                .font(Typo.number(Typo.Size.caption, .regular)).foregroundStyle(theme.inkFaint)
                .frame(width: 50, alignment: .trailing).lineLimit(1).padding(.top, 2)
            VStack(spacing: 0) {
                Circle().fill(theme.accent).frame(width: 6, height: 6).padding(.top, 5)
                if !last { Rectangle().fill(theme.inkFaint.opacity(0.35)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(reasonLabel(e.reason)).font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.accentDeep)
                if let text = e.text {
                    let open = expanded.contains(e.id)
                    Text(text.replacingOccurrences(of: "\n\n", with: "\n"))
                        .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        .lineLimit(open ? nil : 3).lineSpacing(3)
                        .onTapGesture { withAnimation(.snappy) { if open { expanded.remove(e.id) } else { expanded.insert(e.id) } } }
                    if let conv = e.conversationID, let mid = e.messageID {
                        Button { moment = MomentOpen(conversation: conv, message: mid) } label: {
                            Text("去聊天里看 ›").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("这句后来被撤回了").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, last ? 0 : 14)
        }
    }
}
