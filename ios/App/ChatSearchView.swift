import SwiftUI

// 聊天记录搜索 + 聊天日历：从之前自用的 App ChatSearchView.swift / ChatCalendarView.swift 搬来（09-27 那版：搜索交给服务器，秒出）。
// 改的地方：颜色跟着聊天页的深浅走（之前自用的 App这两页永远是浅色）；只搜说出口的话，思考链不进（服务器口径）；
// 点结果交给聊天页决定——在眼前就滚过去亮一下，不在就开「回到那天」。

/// 两页共用的皮：跟聊天页同一套深浅和主题色
private struct SearchSkin {
    let skin: ChatSkin
    var ink: Color { skin.ink }
    var dim: Color { skin.inkDim }
    var faint: Color { skin.inkFaint }

    @ViewBuilder
    func background(theme: AppTheme) -> some View {
        if let bg = skin.pageBackground {
            bg.ignoresSafeArea()
        } else {
            AppBackground(choiceOverride: theme.chatBgChoice != "same" ? theme.chatBgChoice : nil, darkVeil: skin.darkVeil)
        }
    }
}

/// 聊天记录搜索：关键词全文搜，点结果跳到原消息；📅 按日期回到那天
struct ChatSearchView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chatAppearance") private var appearanceRaw = ChatAppearance.light.rawValue   // 新用户默认浅色（Tilia 10-04）

    let companionName: String
    /// 点了一条：交给聊天页（传的是服务器消息号）
    let onOpen: (Int) -> Void

    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searching = false
    @State private var searchedFor = ""        // 结果对应的是哪个词（「没搜到」只在搜完后说）
    @State private var failed = false
    @State private var showCalendar = false
    @FocusState private var focused: Bool

    private var look: SearchSkin {
        SearchSkin(skin: ChatSkin(mode: ChatAppearance(rawValue: appearanceRaw) ?? .dark, accent: theme.accent, scale: 1))
    }

    private func runSearch(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []; searchedFor = ""; searching = false; failed = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))   // 打字时别每个字都去问
        if Task.isCancelled { return }
        searching = true
        let found = await chat.search(trimmed)
        if Task.isCancelled { return }
        searching = false
        results = found ?? []
        searchedFor = found == nil ? "" : trimmed
        failed = found == nil
    }

    var body: some View {
        ZStack {
            look.background(theme: theme)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(Typo.icon(14))
                            .foregroundStyle(look.faint)
                        TextField("", text: $query, prompt: Text("搜关键词…").foregroundStyle(look.faint))
                            .focused($focused)
                            .font(Typo.sans(Typo.Size.body))
                            .foregroundStyle(look.ink)
                            .tint(theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(paintedChrome(Capsule(), skin: look.skin, light: .fromBottom))
                    // 聊天日历：不搜关键词，按日期回到那天
                    Button {
                        showCalendar = true
                    } label: {
                        Image(systemName: "calendar")
                            .font(Typo.icon(17))
                            .foregroundStyle(theme.accent)
                    }
                    Button("取消") { dismiss() }
                        .font(Typo.sans(Typo.Size.body))
                        .foregroundStyle(look.dim)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                if searching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("在找…")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(look.faint)
                    }
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if failed && !searching {
                            Text("没连上，等一下再搜")
                                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(look.dim)
                                .padding(.top, 30)
                        } else if !searchedFor.isEmpty && !searching && results.isEmpty {
                            Text("没搜到「\(searchedFor)」")
                                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(look.dim)
                                .padding(.top, 30)
                        }
                        ForEach(results) { hit in
                            resultRow(hit)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear { focused = true }
        .task(id: query) { await runSearch(query) }
        .sheet(isPresented: $showCalendar) {
            ChatCalendarView { firstID in
                showCalendar = false
                onOpen(firstID)
            }
            .environmentObject(theme)
            .environmentObject(chat)
        }
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let msg = hit.message
        let mine = msg.role == "user"
        return Button {
            onOpen(msg.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(who: mine ? .me : .ai, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(msg.text))
                        .font(Typo.sans(Typo.Size.body))
                        .foregroundStyle(look.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text("\(mine ? "我" : companionName) · \(msg.at.formatted(.dateTime.month().day().hour().minute()))")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(look.faint)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.turn.down.right")
                    .font(Typo.icon(11)).foregroundStyle(look.faint)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(paintedChrome(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous), skin: look.skin))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = msg.text
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
    }

    /// 命中的关键词标成主题色粗体
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: trimmed, options: .caseInsensitive) {
            attributed[range].foregroundColor = theme.accent
            attributed[range].font = Typo.sans(Typo.Size.body, .bold)
            searchStart = range.upperBound
        }
        return attributed
    }
}

/// 聊天日历（之前自用的 App 08-16，底本是 tsuru0805/chat-history-jump 的日历视图的思路）：哪天聊过一眼看见——
/// 日期下的圆点越深、那天话越多；点日期落到那天第一条，然后上下随便翻。
struct ChatCalendarView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chatAppearance") private var appearanceRaw = ChatAppearance.light.rawValue   // 新用户默认浅色（Tilia 10-04）

    let onPick: (Int) -> Void

    @State private var days: [String: CalendarDay] = [:]
    @State private var loading = true
    @State private var monthCursor = Date()

    private let cal = Calendar.current

    private var look: SearchSkin {
        SearchSkin(skin: ChatSkin(mode: ChatAppearance(rawValue: appearanceRaw) ?? .dark, accent: theme.accent, scale: 1))
    }

    /// 日期 → "2026-09-28"（跟服务器的 day 键对齐；强制公历）
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        ZStack {
            look.background(theme: theme)
            VStack(spacing: 14) {
                HStack {
                    Text("聊天日历")
                        .font(Typo.sans(Typo.Size.headline, .semibold))
                        .foregroundStyle(look.ink)
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(Typo.sans(Typo.Size.body))
                        .foregroundStyle(theme.accent)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                monthHeader
                    .padding(.horizontal, 20)

                weekdayRow
                    .padding(.horizontal, 16)

                if loading {
                    ProgressView().padding(.top, 40)
                } else {
                    monthGrid
                        .padding(.horizontal, 16)
                }
                Spacer(minLength: 0)
            }
        }
        .task {
            let list = await chat.calendar()
            days = Dictionary(uniqueKeysWithValues: list.map { ($0.day, $0) })
            loading = false
        }
    }

    // MARK: - 月份导航

    private var monthHeader: some View {
        HStack {
            Button {
                if let previous = cal.date(byAdding: .month, value: -1, to: monthCursor) { monthCursor = previous }
            } label: {
                Image(systemName: "chevron.left")
                    .font(Typo.icon(15, .semibold))
                    .foregroundStyle(canGoBack ? theme.accent : look.faint.opacity(0.4))
                    .frame(width: 40, height: 32)
            }
            .disabled(!canGoBack)
            Spacer()
            Text(monthTitle)
                .font(Typo.sans(Typo.Size.headline, .semibold))
                .foregroundStyle(look.ink)
            Spacer()
            Button {
                if let next = cal.date(byAdding: .month, value: 1, to: monthCursor) { monthCursor = next }
            } label: {
                Image(systemName: "chevron.right")
                    .font(Typo.icon(15, .semibold))
                    .foregroundStyle(canGoForward ? theme.accent : look.faint.opacity(0.4))
                    .frame(width: 40, height: 32)
            }
            .disabled(!canGoForward)
        }
    }

    private var monthTitle: String {
        let parts = cal.dateComponents([.year, .month], from: monthCursor)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月"
    }

    private func monthStart(of date: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// 最早有记录的月份之前不给翻
    private var canGoBack: Bool {
        guard let earliestKey = days.keys.min(),
              let earliest = Self.keyFormatter.date(from: earliestKey) else { return false }
        return monthStart(of: monthCursor) > monthStart(of: earliest)
    }

    /// 未来不给翻
    private var canGoForward: Bool {
        monthStart(of: monthCursor) < monthStart(of: Date())
    }

    // MARK: - 网格

    /// 周首日跟随系统
    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(Typo.sans(Typo.Size.caption))
                    .foregroundStyle(look.faint)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 当月每一格：开头的空位是 nil
    private var gridDates: [Date?] {
        let start = monthStart(of: monthCursor)
        guard let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let leadingBlanks = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in range {
            cells.append(cal.date(byAdding: .day, value: day - 1, to: start))
        }
        return cells
    }

    /// 圆点深浅按当月话最多的那天归一
    private var monthMaxCount: Int {
        let monthKey = Self.keyFormatter.string(from: monthStart(of: monthCursor)).prefix(7)
        return days.filter { $0.key.hasPrefix(monthKey) }.map(\.value.count).max() ?? 1
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(Array(gridDates.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let key = Self.keyFormatter.string(from: date)
        let info = days[key]
        let isToday = cal.isDateInToday(date)
        return Button {
            if let info { onPick(info.firstID) }
        } label: {
            VStack(spacing: 4) {
                Text("\(cal.component(.day, from: date))")
                    .font(Typo.sans(Typo.Size.body, info != nil ? .semibold : .regular))
                    .foregroundStyle(info != nil ? look.ink : look.faint.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .background {
                        if isToday { Circle().fill(theme.accent.opacity(0.16)) }
                    }
                Circle()
                    .fill(info != nil ? theme.accent.opacity(dotOpacity(info!.count)) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .buttonStyle(.plain)
        .disabled(info == nil)
    }

    private func dotOpacity(_ count: Int) -> Double {
        let t = min(1.0, Double(count) / Double(max(monthMaxCount, 1)))
        return 0.3 + 0.7 * t
    }
}
