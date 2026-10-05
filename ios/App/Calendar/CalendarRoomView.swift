import EventKit
import SwiftUI

// MARK: - 日历（10-01 Tilia：它记着的日子 + 有时间的待办 + 手机日历里自己写的事，放在一起看；朴素版，样子等统一调 UI）
//
// 「它记着的事」（远事）以后住这里：联系人设置里那张清单换成一句指路。手机日历只读、只看你自己的日历——
// 订阅来的节假日、生日那种不放（Tilia：random 节日加进去看着乱）。点某一天「加」：让它惦记着（远事）还是待办。

extension Notification.Name {
    static let lumiOpenCalendar = Notification.Name("LumiOpenCalendar")
}

/// 手机日历：只要自己写的（本机、iCloud、Exchange…），订阅的节假日和生日不要
enum PhoneCalendar {
    static func own(_ store: EKEventStore) -> [EKCalendar] {
        store.calendars(for: .event).filter { $0.type != .subscription && $0.type != .birthday }
    }

    /// 只从自己的日历里拿；一个自己的日历都没有就是空（给 EventKit 空列表可能被当成「全部」）
    static func events(_ store: EKEventStore, from start: Date, to end: Date) -> [EKEvent] {
        let mine = own(store)
        guard !mine.isEmpty else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: mine))
    }
}

private struct DayEntry: Identifiable {
    enum Kind { case far, todo, phone }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let time: String
    var far: FarDateDTO?
    var farCompanion: CompanionDTO?
    var todo: TodoDTO?
}

struct CalendarRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("calendarShowPhone") private var showPhone = false
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var fars: [(CompanionDTO, FarDateDTO)] = []
    @State private var todos: [TodoDTO] = []
    @State private var places: [PlaceDTO] = []
    @State private var phone: [EKEvent] = []
    @State private var error: String?
    @State private var asking = false
    @State private var addingFar = false
    @State private var editingFar: (CompanionDTO, FarDateDTO)?
    @State private var addingTodo = false
    @State private var editingTodo: TodoDTO?
    private let store = EKEventStore()

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                    monthHeader
                    grid
                    legend
                    dayList
                    Toggle(isOn: $showPhone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("显示手机日历").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                            Text("只放你自己写的，订阅的节假日和生日不放；只看不改")
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle("日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { asking = true } label: { Image(systemName: "plus") } }
            }
            .confirmationDialog(String(localized: "\(selected.formatted(.dateTime.month().day())) 加一条"), isPresented: $asking,
                                titleVisibility: .visible) {
                Button(String(localized: "让 \(mainName) 惦记着（前一晚、当天、第二天都会来找你）")) { addingFar = true }
                Button("待办（到点提醒一次）") { addingTodo = true }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $addingFar) {
                AddDateView(existing: nil, startDay: selected) { body in Task { await saveFar(nil, body) } }
            }
            .sheet(item: Binding(get: { editingFar.map { FarEdit(c: $0.0, d: $0.1) } }, set: { if $0 == nil { editingFar = nil } })) { e in
                AddDateView(existing: e.d, onDelete: { Task { await deleteFar(e) } }) { body in Task { await saveFar(e, body) } }
            }
            .sheet(isPresented: $addingTodo) {
                TodoEditor(todo: nil, places: places, startDay: selected) { await load() }
                    .environmentObject(model).environmentObject(theme)
            }
            .sheet(item: $editingTodo) { t in
                TodoEditor(todo: t, places: places) { await load() }.environmentObject(model).environmentObject(theme)
            }
        }
        .environment(\.colorScheme, .light)
        .task { await load() }
        .onChange(of: showPhone) { _, _ in Task { await loadPhone() } }
        .onChange(of: month) { _, _ in Task { await loadPhone() } }
    }

    private var mainName: String { model.companions.first?.name ?? "Ta" }

    // MARK: 月

    private var monthHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.formatted(.dateTime.year().month(.wide))).font(Typo.sans(Typo.Size.headline, .semibold))
                .foregroundStyle(theme.ink)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
        }
        .foregroundStyle(theme.accentDeep)
    }

    private func shift(_ n: Int) {
        month = cal.date(byAdding: .month, value: n, to: month) ?? month
    }

    private var days: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                Text(w).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            }
            ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                if let d { dayCell(d) } else { Color.clear.frame(height: 44) }
            }
        }
    }

    private func dayCell(_ d: Date) -> some View {
        let on = cal.isDate(d, inSameDayAs: selected)
        let today = cal.isDateInToday(d)
        let kinds = Set(entries(on: d).map(\.kind))
        return Button { selected = d } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: d))")
                    .font(Typo.sans(Typo.Size.callout, today ? .bold : .regular))
                    .foregroundStyle(on ? Color.white : theme.ink)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(on ? theme.accentDeep : (today ? theme.accentDeep.opacity(0.14) : .clear)))
                HStack(spacing: 2) {
                    if kinds.contains(.far) { dot(theme.accentDeep) }
                    if kinds.contains(.todo) { dot(theme.ink.opacity(0.55)) }
                    if kinds.contains(.phone) { dot(theme.inkDim.opacity(0.4)) }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private func dot(_ c: Color) -> some View { Circle().fill(c).frame(width: 5, height: 5) }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) { dot(theme.accentDeep); Text(String(localized: "\(mainName) 记着的")) }
            HStack(spacing: 4) { dot(theme.ink.opacity(0.55)); Text("待办") }
            if showPhone { HStack(spacing: 4) { dot(theme.inkDim.opacity(0.4)); Text("手机日历") } }
        }
        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
    }

    // MARK: 那一天

    private var dayList: some View {
        let list = entries(on: selected)
        return VStack(alignment: .leading, spacing: 10) {
            Text(selected.formatted(.dateTime.month().day().weekday(.wide)))
                .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
            if list.isEmpty {
                Text("这天没什么事。右上角 ＋ 可以加一条。").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            }
            ForEach(list) { e in
                Button { open(e) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(e.kind == .far ? theme.accentDeep : e.kind == .todo ? theme.ink.opacity(0.55) : theme.inkDim.opacity(0.4))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                            if !e.detail.isEmpty {
                                Text(e.detail).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(e.time).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
                .buttonStyle(.plain)
                .disabled(e.kind == .phone)
            }
        }
    }

    private func open(_ e: DayEntry) {
        if let f = e.far, let c = e.farCompanion { editingFar = (c, f) }
        if let t = e.todo { editingTodo = t }
    }

    /// 某一天有什么：远事（按那天）、待办（一次的按那天，每天 / 每周的按星期展开）、手机日历
    private func entries(on d: Date) -> [DayEntry] {
        let key = Self.ymd.string(from: d)
        var out: [DayEntry] = []
        let many = model.companions.count > 1
        for (c, f) in fars where f.day == key {
            out.append(DayEntry(id: "f\(f.id)", kind: .far, title: f.title,
                                detail: [many ? String(localized: "\(c.name) 记着") : "", f.note].filter { !$0.isEmpty }.joined(separator: " · "),
                                time: f.time, far: f, farCompanion: c))
        }
        let wd = (cal.component(.weekday, from: d) + 5) % 7            // 周一 = 0
        for t in todos {
            var hit = false, time = ""
            if t.shape == "once", let at = t.spec.at, let when = APIClient.parseDate(at) {
                hit = cal.isDate(when, inSameDayAs: d); time = Self.hm.string(from: when)
            } else if t.shape == "at", let tm = t.spec.time {
                let ds = t.spec.days ?? []
                hit = ds.isEmpty || ds.contains(wd); time = tm
            }
            guard hit else { continue }
            out.append(DayEntry(id: "t\(t.id)-\(key)", kind: .todo, title: (t.done ? "✓ " : "") + t.what,
                                detail: t.place.map { t.placeOn == "leave" ? String(localized: "离开\($0)时") : String(localized: "到\($0)时") } ?? "",
                                time: time, todo: t))
        }
        if showPhone {
            for ev in phone where cal.isDate(ev.startDate, inSameDayAs: d)
                || (ev.startDate < d && ev.endDate > d) {
                out.append(DayEntry(id: "p\(ev.eventIdentifier ?? UUID().uuidString)-\(key)", kind: .phone, title: ev.title ?? "",
                                    detail: ev.calendar.title, time: ev.isAllDay ? String(localized: "全天") : Self.hm.string(from: ev.startDate)))
            }
        }
        return out.sorted { ($0.time.isEmpty ? "99" : $0.time) < ($1.time.isEmpty ? "99" : $1.time) }
    }

    // MARK: 数据

    private func load() async {
        do {
            var got: [(CompanionDTO, FarDateDTO)] = []
            for c in model.companions {
                let ds: [FarDateDTO] = try await model.api.call("GET", "companions/\(c.id.uuidString.lowercased())/dates")
                got += ds.map { (c, $0) }
            }
            fars = got
            todos = try await model.api.call("GET", "todos")
            places = (try? await model.api.call("GET", "places")) ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
        await loadPhone()
    }

    private func loadPhone() async {
        guard showPhone else { phone = []; return }
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard (try? await store.requestFullAccessToEvents()) == true else {
                error = String(localized: "没拿到日历权限。去「设置 → Mele → 日历」打开。"); showPhone = false; return
            }
        }
        let start = cal.date(byAdding: .day, value: -7, to: month) ?? month
        let end = cal.date(byAdding: .month, value: 1, to: month).flatMap { cal.date(byAdding: .day, value: 7, to: $0) } ?? month
        phone = PhoneCalendar.events(store, from: start, to: end)
    }

    private func deleteFar(_ e: FarEdit) async {
        do { try await model.api.send("DELETE", "dates/\(e.d.id)"); await load() } catch { self.error = error.localizedDescription }
    }

    private func saveFar(_ e: FarEdit?, _ body: [String: Any]) async {
        do {
            if let e {
                let _: FarDateDTO = try await model.api.call("PATCH", "dates/\(e.d.id)", json: body)
            } else if let c = model.companions.first {
                let _: FarDateDTO = try await model.api.call("POST", "companions/\(c.id.uuidString.lowercased())/dates", json: body)
            }
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

private struct FarEdit: Identifiable {
    let c: CompanionDTO
    let d: FarDateDTO
    var id: Int { d.id }
}
