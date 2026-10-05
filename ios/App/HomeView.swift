import SwiftUI

/// 首页（第二块）：问候 + 小组件墙。这一步先只有问候和头像卡，墙在第 8 步。
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var editing = false
    @State private var wakeFor: WakeTarget?
    @State private var coachFrames: [String: CGRect] = [:]
    @State private var showTour = false

    struct WakeTarget: Identifiable { let id: UUID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HomeGreeting()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topTrailing) {
                        if editing {
                            Button { withAnimation(.snappy) { editing = false } } label: {
                                Text("完成").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.accentDeep)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(.regularMaterial))
                            }
                            .buttonStyle(.plain)
                            .offset(y: -30)
                        }
                    }
                if model.recentCompanion != nil {
                    VStack(spacing: 8) {
                        PrimaryCard()
                        AllMessagesStrip()
                    }
                    .opacity(editing ? 0.5 : 1)
                    .allowsHitTesting(!editing)
                    WidgetWall(editing: $editing, onOpenWakes: { wakeFor = WakeTarget(id: $0) })
                        .onReceive(NotificationCenter.default.publisher(for: .lumiOpenWakes)) { _ in
                            if let c = model.primaryCompanion { wakeFor = WakeTarget(id: c.id) }
                        }
                        .padding(.top, 4)
                        .coachMark("wall")
                } else if let err = model.loadError {
                    Text(err).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    Button("再试一次") { Task { await model.refresh() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .fullScreenCover(item: $wakeFor) { t in SelfWakeView(companionID: t.id) }
        .onPreferenceChange(CoachFrameKey.self) { coachFrames = $0 }
        .overlay {
            if showTour {
                CoachOverlay(steps: [CoachStep(id: "wall", text: String(localized: "长按卡片：换位置、换大小、加新卡"))],
                             frames: coachFrames) {
                    withAnimation { showTour = false }
                    CoachTour.done(CoachTour.homeKey)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            // 第一次回首页（聊天页那段看完了）再放
            guard CoachTour.pending(CoachTour.homeKey), !CoachTour.pending(CoachTour.chatKey), model.chat == nil else { return }
            Task { try? await Task.sleep(for: .seconds(0.8)); withAnimation { showTour = true } }
        }
        .onChange(of: model.chat) { _, c in
            guard c == nil, CoachTour.pending(CoachTour.homeKey), !CoachTour.pending(CoachTour.chatKey) else { return }
            Task { try? await Task.sleep(for: .seconds(0.8)); withAnimation { showTour = true } }
        }
    }
}

/// 顶上的问候：点缀字写时段（英文），下一行系统字写名字和日期——中英不放一个 Text（字体规矩）
struct HomeGreeting: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.period(ctx.date))
                    .font(Typo.accent(Typo.Size.largeTitle))
                    .foregroundStyle(theme.ink)
                    .titleBar()
                Text(subtitle(ctx.date))
                    .font(Typo.sans(Typo.Size.body))
                    .foregroundStyle(theme.inkDim)
            }
        }
        .padding(.top, 8)
    }

    static func period(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Good night"
        }
    }

    private func subtitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        let name = model.profile?.name ?? ""
        return name.isEmpty ? f.string(from: d) : "\(name) · \(f.string(from: d))"
    }
}

/// 主聊天人（Tilia 09-28）：点了直接进聊天；卡角切「最近 / 最常聊」，选哪个记本机
struct PrimaryCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("primaryPick") private var pick = "recent"      // recent / busiest

    private var companion: CompanionDTO? {
        pick == "busiest" ? (model.busiestCompanion ?? model.recentCompanion) : model.recentCompanion
    }

    var body: some View {
        if let c = companion {
            Button { Task { await model.openChat(c) } } label: {
                HStack(spacing: 14) {
                    CompanionAvatar(companion: c, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.name).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                            Spacer()
                            if let at = model.lastAt(c.id) {
                                Text(ChatTime.short(at)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            }
                        }
                        HStack {
                            Text(model.preview(c.id))
                                .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).lineLimit(1)
                            Spacer(minLength: 0)
                            if model.hasUnread(c.id) { UnreadDot() }
                        }
                    }
                }
                .padding(16)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) { pickToggle }
        }
    }

    /// 卡角的小切换：只有一个联系人时不显示（切了也一样）
    @ViewBuilder private var pickToggle: some View {
        if model.companions.count > 1 {
            HStack(spacing: 0) {
                ForEach([("recent", "最近"), ("busiest", "最常聊")], id: \.0) { key, label in
                    Button { withAnimation(.snappy(duration: 0.2)) { pick = key } } label: {
                        Text(label)
                            .font(Typo.sans(Typo.Size.caption, pick == key ? .semibold : .regular))
                            .foregroundStyle(pick == key ? theme.accentDeep : theme.inkFaint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background { if pick == key { Capsule().fill(Color.white.opacity(0.8)) } }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.black.opacity(0.04)))
            .padding(10)
        }
    }
}

/// 主聊天人下面那条窄的：点了才推开完整的消息列表
struct AllMessagesStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme

    private var unreadOthers: Int {
        model.companions.filter { model.hasUnread($0.id) }.count
    }

    var body: some View {
        Button { withAnimation(MainTabView.slide) { model.listOpen = true } } label: {
            HStack {
                Text("全部消息").font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.inkDim)
                if unreadOthers > 0 {
                    Text("\(unreadOthers)")
                        .font(Typo.number(Typo.Size.caption)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(theme.inkDim))
                }
                Spacer()
                Image(systemName: "chevron.right").font(Typo.icon(12, .semibold)).foregroundStyle(theme.inkFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .capsuleSurface()
        }
        .buttonStyle(.plain)
    }
}

/// 列表里的时间：今天写几点，昨天写「昨天」，一周内写星期，再早写日期
enum ChatTime {
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale.current
        if cal.isDateInToday(d) { f.setLocalizedDateFormatFromTemplate("jmm"); return f.string(from: d) }
        if cal.isDateInYesterday(d) { return String(localized: "昨天") }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEEE"); return f.string(from: d)
        }
        f.setLocalizedDateFormatFromTemplate("Md")
        return f.string(from: d)
    }
}
