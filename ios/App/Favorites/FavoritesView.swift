import SwiftUI

// MARK: - 收藏夹（10-02，移植自之前自用的 App FavoritesView：全部 / 日历两种看法，同组的折成一块，点一条回到那天）
//
// Mele 多了「是跟谁聊的」：每条带那个联系人的头像和名字；联系人不止一个时顶上一排胶囊筛。
// 日历按收藏的那天分格（之前自用的 App的口径：她收的那天才是「那天」）。

struct FavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var avatars: AvatarStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavoritesStore.shared

    @AppStorage("favorites.calendarMode") private var calendarMode = false
    @State private var only: UUID?
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var pickedDay: PickedDay?
    @State private var moment: FavoriteMoment?
    @State private var gone = false

    struct PickedDay: Identifiable { let day: Date; var id: Date { day } }
    struct FavoriteMoment: Identifiable { let companion: UUID; let conversation: UUID; let message: Int; var id: Int { message } }

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }

    private var shown: [FavoriteDTO] {
        guard let only else { return store.items }
        return store.items.filter { $0.companionID == only }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if model.companions.count > 1 { filter }
                    if !store.loaded {
                        ProgressView().padding(.top, 60)
                    } else if shown.isEmpty {
                        empty
                    } else if calendarMode {
                        PhoneGlassCard(padding: 14) { calendar }
                        Text("点有点的日子，看那天收的")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    } else {
                        FavoriteBlocks(blocks: FavoritesStore.blocks(shown), onJump: jump)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(AppBackground())
            .navigationTitle("收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { calendarMode.toggle() }
                    } label: {
                        Image(systemName: calendarMode ? "list.bullet" : "calendar")
                    }
                    .accessibilityLabel(calendarMode ? "看全部" : "按日历看")
                }
            }
        }
        .environment(\.colorScheme, .light)
        .task { await store.load(session.api) }
        .sheet(item: $pickedDay) { d in
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        FavoriteBlocks(blocks: FavoritesStore.blocks(shown.filter { cal.isDate($0.savedAt, inSameDayAs: d.day) })) { f in
                            pickedDay = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { jump(f) }
                        }
                    }
                    .padding(20)
                }
                .background(AppBackground())
                .navigationTitle(d.day.formatted(.dateTime.month().day().weekday()))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .environment(\.colorScheme, .light)
        }
        .fullScreenCover(item: $moment) { m in
            MomentRoom(companionID: m.companion, conversation: m.conversation, anchor: m.message, api: session.api)
        }
        .alert("那个窗口已经删掉了", isPresented: $gone) {
            Button("好") {}
        } message: {
            Text("收藏还留着，只是回不到原来的位置了。")
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart")
                .font(Typo.icon(40)).foregroundStyle(theme.accent)
            Text("还没有收藏")
                .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Text("在聊天里长按一句，选「收藏」；多选可以把一段对话收成一组")
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }

    private var filter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "全部"), on: only == nil) { only = nil }
                ForEach(model.companions) { c in
                    chip(c.name, on: only == c.id) { only = c.id }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typo.sans(Typo.Size.callout, on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? theme.accentDeep : Color.white.opacity(0.55)))
        }
        .buttonStyle(.plain)
    }

    /// 跳回原位：窗口还在就开「回到那天」，不在了说一声
    private func jump(_ f: FavoriteDTO) {
        let windows = model.conversations[f.companionID] ?? []
        if windows.contains(where: { $0.id == f.conversationID }) {
            moment = FavoriteMoment(companion: f.companionID, conversation: f.conversationID, message: f.messageID)
        } else {
            gone = true
        }
    }

    // MARK: 日历

    private var calendar: some View {
        let counts = Dictionary(grouping: shown) { cal.startOfDay(for: $0.savedAt) }.mapValues(\.count)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(spacing: 10) {
            HStack {
                Button { month = cal.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(month.formatted(.dateTime.year().month(.wide)))
                    .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Spacer()
                Button { month = cal.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
            }
            .foregroundStyle(theme.accentDeep)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
                // [Date?] 拍平 + id 用位置（之前自用的 App 09-03 踩过：空格和日子分两个 ForEach 会撞 id）
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, d in
                    if let d {
                        let n = counts[d] ?? 0
                        Button { if n > 0 { pickedDay = PickedDay(day: d) } } label: {
                            VStack(spacing: 3) {
                                Text("\(cal.component(.day, from: d))")
                                    .font(Typo.sans(Typo.Size.callout, cal.isDateInToday(d) ? .bold : .regular))
                                    .foregroundStyle(n > 0 ? theme.ink : theme.inkFaint)
                                Circle().fill(n > 0 ? theme.accentDeep : .clear).frame(width: 5, height: 5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
    }

    private var monthDays: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }
}

/// 收藏的列表体：单条一张卡，同组折成一块（默认收起，点标题展开）。列表页和「那一天」共用。
struct FavoriteBlocks: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var store = FavoritesStore.shared
    let blocks: [[FavoriteDTO]]
    var onJump: (FavoriteDTO) -> Void

    @State private var expanded: Set<UUID> = []

    var body: some View {
        ForEach(blocks, id: \.first!.id) { block in
            if block.count == 1 { row(block[0]) } else { group(block) }
        }
    }

    private func name(_ f: FavoriteDTO) -> String {
        f.mine ? String(localized: "我") : (model.companion(f.companionID)?.name ?? "Ta")
    }

    @ViewBuilder
    private func avatar(_ f: FavoriteDTO, size: CGFloat) -> some View {
        if !f.mine, let c = model.companion(f.companionID) {
            CompanionAvatar(companion: c, size: size)
        } else {
            Circle().fill(theme.accentSoft)
                .overlay(Text(name(f).prefix(1)).font(Typo.icon(size * 0.42, .semibold)).foregroundStyle(theme.accentDeep))
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func content(_ f: FavoriteDTO, lines: Int?) -> some View {
        if !f.images.isEmpty {
            HStack(spacing: 6) {
                ForEach(f.images.prefix(3)) { img in
                    AuthImageView(urlPath: "attachments/\(img.id.uuidString.lowercased())")
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: Radii.chip, style: .continuous))
                }
            }
        }
        if !f.text.isEmpty {
            Text(f.text)
                .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ f: FavoriteDTO) -> some View {
        PhoneGlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                avatar(f, size: 30)
                VStack(alignment: .leading, spacing: 6) {
                    content(f, lines: nil)
                    Text("\(name(f)) · \(f.saidAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.turn.down.right")
                    .font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onJump(f) }
        .contextMenu {
            Button(role: .destructive) { Task { await store.remove(f, api: session.api) } } label: {
                Label("移出收藏", systemImage: "heart.slash")
            }
        }
    }

    private func group(_ block: [FavoriteDTO]) -> some View {
        let gid = block[0].groupID ?? UUID()
        let open = expanded.contains(gid)
        return PhoneGlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill").font(Typo.icon(12)).foregroundStyle(theme.accentDeep)
                    Text("一段对话 · \(block.count) 条")
                        .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.accentDeep)
                    Spacer()
                    Text(block[0].savedAt.formatted(.dateTime.month().day()))
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    Image(systemName: "chevron.down")
                        .font(Typo.icon(11, .semibold)).foregroundStyle(theme.inkFaint)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.22)) {
                        if open { expanded.remove(gid) } else { expanded.insert(gid) }
                    }
                }
                if !open {
                    Text(block[0].text.isEmpty ? String(localized: "［图片］") : block[0].text)
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .lineLimit(1)
                } else {
                    ForEach(block) { f in
                        HStack(alignment: .top, spacing: 8) {
                            avatar(f, size: 22)
                            VStack(alignment: .leading, spacing: 4) { content(f, lines: 4) }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onJump(f) }
                        if f.id != block.last?.id { Divider().overlay(Color.white.opacity(0.35)) }
                    }
                    Text("点任意一条回到那天")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
        }
        .contextMenu {
            Button(role: .destructive) { Task { await store.removeGroup(gid, api: session.api) } } label: {
                Label("整组移出收藏", systemImage: "heart.slash")
            }
        }
    }
}
