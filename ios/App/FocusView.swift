import DeviceActivity
import FamilyControls
import SwiftUI
import UserNotifications
import WidgetKit

// MARK: - 哨兵 · 主 app 这一半（09-29，设计 specs/2026-09-29-ios-focus-sentinel-design.md）
//
// 开始：要屏幕使用时间授权（TA 管自己）→ 服务器让 TA 的 Lumi 写 5 条提醒（允许的话再定第几条后锁）→ 写进 App Group →
// 开监控（选中的 app 累计 1/3/6/10/15 分钟各一个事件）→ 开了「锁住」就先加挡板。
// 结束：停监控、撤挡板、把分心几条 / 几分钟、是不是提前结束报给服务器。回前台发现已经到点就自动结束。

extension Notification.Name {
    /// 打开专注页（首页小组件、聊天里的卡片都发这个；userInfo 可带 minutes / label 预填）
    static let lumiOpenFocus = Notification.Name("LumiOpenFocus")
    /// 专注时它说的话报上去了，聊天页补拉一下
    static let lumiFocusSaid = Notification.Name("LumiFocusSaid")
    /// 小组件点开「今天来找过你」：首页开主联系人的自唤醒页
    static let lumiOpenWakes = Notification.Name("LumiOpenWakes")
    /// 它改了你们的关系（09-29）：刷联系人，聊天页名字旁边的图标跟着换
    static let lumiRelationshipChanged = Notification.Name("LumiRelationshipChanged")
}

struct FocusPrefill: Identifiable {
    let id = UUID()
    var minutes = 45
    var label = ""

    /// 聊天卡片上的字「复习期末 · 120 分钟」/「专注 120 分钟」→ userInfo
    static func parse(_ text: String) -> [String: Any] {
        let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        let label = text.components(separatedBy: " · ").count > 1 ? text.components(separatedBy: " · ")[0] : ""
        return ["minutes": Int(digits.last ?? "") ?? 45, "label": label]
    }
}

@MainActor
final class FocusStore: ObservableObject {
    static let shared = FocusStore()
    @Published var session: FocusSession? = FocusSession.load()
    @Published var selection = FocusSelection.load()
    @Published var error: String?

    var running: Bool { session != nil }

    func pick(_ s: FamilyActivitySelection) {
        selection = s
        FocusSelection.save(s)
    }

    func start(api: APIClient, conversation: UUID, companionName: String, minutes: Int, label: String,
               lockNow: Bool, allowLumiLock: Bool) async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            // 提醒是插件弹的本机通知：Lite 本机模式启动时不要通知权限，这里补要一次（给过 / 拒过都不会再弹）
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            struct Out: Decodable {
                let id: String; let lines: [String]; let lockAfter: Int; let peekLine: String
                enum CodingKeys: String, CodingKey { case id, lines; case lockAfter = "lock_after"; case peekLine = "peek_line" }
            }
            let out: Out = try await api.call("POST", "conversations/\(conversation.lowercased)/focus/start",
                                             json: ["minutes": minutes, "label": label, "allow_lock": allowLumiLock,
                                                    "lock_now": lockNow])
            let now = Date(), end = now.addingTimeInterval(TimeInterval(minutes * 60))
            let s = FocusSession(id: out.id, start: now, end: end, label: label, companionName: companionName,
                                 lines: out.lines, lockNow: lockNow, lockAfter: allowLumiLock ? out.lockAfter : 0,
                                 peekLine: out.peekLine)
            s.save()
            let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
            let schedule = DeviceActivitySchedule(intervalStart: Calendar.current.dateComponents(parts, from: now),
                                                  intervalEnd: Calendar.current.dateComponents(parts, from: end),
                                                  repeats: false)
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            for (i, m) in FocusShared.thresholds.enumerated() {
                events[FocusShared.eventName(i + 1)] = DeviceActivityEvent(
                    applications: selection.applicationTokens, categories: selection.categoryTokens,
                    webDomains: selection.webDomainTokens, threshold: DateComponents(minute: m))
            }
            let center = DeviceActivityCenter()
            center.stopMonitoring([FocusShared.activity])
            try center.startMonitoring(FocusShared.activity, during: schedule, events: events)
            if lockNow { Shield.apply() }
            session = s
            error = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            FocusSession.clear()
            self.error = error.localizedDescription
        }
    }

    func end(api: APIClient, early: Bool) async {
        guard let s = FocusSession.load() ?? session else { return }
        await flushSaid(api: api)
        DeviceActivityCenter().stopMonitoring([FocusShared.activity])
        Shield.clear()
        try? await api.send("POST", "focus/\(s.id)/end",
                            json: ["distracted_times": s.reached, "distracted_minutes": s.distractedMinutes, "early": early])
        FocusSession.clear()
        session = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 插件替它弹过的话报给服务器，按原来的时间存进聊天。每次回前台都报——赶在 TA 回来后说第一句之前，聊天顺序才不乱
    func flushSaid(api: APIClient) async {
        let all = FocusOutbox.load()
        guard !all.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        var sent = false
        for (focus, items) in Dictionary(grouping: all, by: \.focus) {
            struct Out: Decodable { let added: Int }
            do {
                let out: Out = try await api.call("POST", "focus/\(focus)/said", json: [
                    "items": items.map { ["key": $0.key, "at": iso.string(from: $0.at), "text": $0.text] }])
                FocusOutbox.remove(items)
                sent = sent || out.added > 0
            } catch let e as APIError where e.status == 404 {
                FocusOutbox.remove(items)             // 这次专注服务器上没有了（换了账号之类），别一直报
            } catch {
                // 连不上：留着，下次回前台再报
            }
        }
        if sent { NotificationCenter.default.post(name: .lumiFocusSaid, object: nil) }
    }

    /// 回前台：先把插件替它说过的话报上去；插件改过的（到了第几条）读回来；已经到点的自动结束
    func refresh(api: APIClient) async {
        await flushSaid(api: api)
        session = FocusSession.load()
        if let s = session, Date() >= s.end { await end(api: api, early: false) }
    }
}

// MARK: - 专注页

struct FocusSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FocusStore.shared
    @State private var minutes: Int
    @State private var label: String
    @State private var lockNow = false
    @State private var allowLumiLock = false
    @State private var picking = false
    @State private var starting = false
    let conversation: UUID?
    let companion: CompanionDTO?

    init(prefill: FocusPrefill, conversation: UUID?, companion: CompanionDTO?) {
        _minutes = State(initialValue: prefill.minutes)
        _label = State(initialValue: prefill.label)
        self.conversation = conversation
        self.companion = companion
    }

    private var name: String { companion?.name ?? "TA" }

    var body: some View {
        NavigationStack {
            Form {
                if let s = store.session { runningSection(s) } else { setup }
                if let err = store.error {
                    Text(err).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("专注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } } }
            .familyActivityPicker(isPresented: $picking, selection: Binding(get: { store.selection }, set: { store.pick($0) }))
        }
        .environment(\.colorScheme, .light)
        .task { await store.refresh(api: model.api) }
    }

    private var setup: some View {
        Group {
            Section {
                // 苹果自带的「小时 / 分钟」滚轮（Tilia 09-29 要的），五分钟一格
                CountdownWheel(minutes: $minutes)
                    .frame(height: 180)
                TextField("在忙什么（比如：背单词）", text: $label)
            } footer: {
                if minutes < 15 { Text("最短 15 分钟（苹果的规定）").foregroundStyle(.red) }
            }
            Section {
                Button {
                    // 先要屏幕使用时间授权再开选择器：没授权时它常常只列分类、看不到 app（Tilia 09-29 真机碰到）
                    Task {
                        do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual) }
                        catch { store.error = error.localizedDescription; return }
                        picking = true
                    }
                } label: {
                    HStack {
                        Text("分心的 app").foregroundStyle(theme.ink)
                        Spacer()
                        Text(FocusSelection.count(store.selection) == 0 ? String(localized: "还没选")
                             : String(localized: "选了 \(FocusSelection.count(store.selection)) 个"))
                            .foregroundStyle(theme.inkDim)
                    }
                    .font(Typo.sans(Typo.Size.body))
                }
            } footer: { Text("app 收在分类下面：点分类右边的小箭头展开，或者在顶上搜名字。看不到 app？去 设置 → 屏幕使用时间，打开「App 与网站活动」。你挑了哪些只存在这台手机上，\(name)和我们的服务器都不知道。") }
            Section {
                Toggle("锁住这些 app", isOn: $lockNow)
                Toggle("允许\(name)锁", isOn: $allowLumiLock)
            } footer: {
                Text("刷分心的 app，累计 1、3、6、10、15 分钟各弹一条\(name)写的提醒。允许\(name)锁，就由\(name)决定刷到第几条还不停就锁住。")
            }
            Section {
                Button {
                    guard let conversation else { return }
                    starting = true
                    Task {
                        await store.start(api: model.api, conversation: conversation, companionName: name, minutes: minutes,
                                          label: label.trimmingCharacters(in: .whitespaces), lockNow: lockNow,
                                          allowLumiLock: allowLumiLock)
                        starting = false
                    }
                } label: {
                    HStack { Spacer(); if starting { ProgressView() } else { Text("开始专注") }; Spacer() }
                        .font(Typo.sans(Typo.Size.body, .semibold))
                }
                .disabled(starting || conversation == nil || minutes < 15 || FocusSelection.count(store.selection) == 0)
            }
        }
    }

    private func runningSection(_ s: FocusSession) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.label.isEmpty ? String(localized: "专注中") : s.label)
                        .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                    Text(String(localized: "还剩 \(max(0, Int(s.end.timeIntervalSinceNow / 60))) 分钟 · 分心 \(s.distractedMinutes) 分钟"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                }
            }
            Button("结束专注", role: .destructive) {
                Task { await store.end(api: model.api, early: Date() < s.end); dismiss() }
            }
        }
    }
}

/// 首页小组件：没专注「开始专注」；专注中还剩多久、分心几分钟
struct FocusCard: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var store = FocusStore.shared
    let size: WidgetSize

    var body: some View {
        Button { NotificationCenter.default.post(name: .lumiOpenFocus, object: nil) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label("专注", systemImage: "timer").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
                Spacer(minLength: 0)
                if let s = store.session {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(String(localized: "还剩 \(max(0, Int(s.end.timeIntervalSinceNow / 60))) 分"))
                            .font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
                    }
                    Text(String(localized: "分心 \(s.distractedMinutes) 分钟")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                } else {
                    Text("开始专注").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 系统的倒计时滚轮（UIDatePicker 的 countDownTimer：小时 + 分钟），SwiftUI 的 DatePicker 没有这个样子
struct CountdownWheel: UIViewRepresentable {
    @Binding var minutes: Int

    func makeUIView(context: Context) -> UIDatePicker {
        let p = UIDatePicker()
        p.datePickerMode = .countDownTimer
        p.minuteInterval = 5
        p.countDownDuration = TimeInterval(minutes * 60)
        p.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return p
    }

    func updateUIView(_ p: UIDatePicker, context: Context) {
        if Int(p.countDownDuration / 60) != minutes { p.countDownDuration = TimeInterval(minutes * 60) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(minutes: $minutes) }

    final class Coordinator: NSObject {
        let minutes: Binding<Int>
        init(minutes: Binding<Int>) { self.minutes = minutes }
        @objc func changed(_ p: UIDatePicker) { minutes.wrappedValue = Int(p.countDownDuration / 60) }
    }
}
