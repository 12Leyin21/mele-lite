import MapKit
import SwiftUI

// MARK: - 待办（10-01 Tilia：三个格子「做什么 / 什么时候 / 在哪」；朴素版，样子等统一调 UI）
//
// 只填「在哪」= 到了 / 离开那里时 Lumi 来提醒（「放学后买东西」= 离开学校）；只填时间 = 到点提醒；
// 两个都填 = 到点时你在那儿才提醒，不在就等你当天到了 / 离开了再提醒。打勾 = 这一期做完（每周的 = 这周）。
// 「你定的钟」都并进来了。

extension Notification.Name {
    static let lumiOpenTodo = Notification.Name("LumiOpenTodo")
}

struct TodoSpecDTO: Decodable, Hashable {
    var at: String?
    var time: String?
    var days: [Int]?
}

struct TodoDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let what: String
    let companion: String
    let companionId: String
    let shape: String?
    let spec: TodoSpecDTO
    let when: String
    let placeId: Int?
    let place: String?
    let placeOn: String?
    let `repeat`: String
    let done: Bool
    enum CodingKeys: String, CodingKey {
        case id, what, companion, shape, spec, when, place, done, `repeat`
        case placeId = "place_id", placeOn = "place_on", companionId = "companion_id"
    }

    /// 不止一个联系人时，每条后面写一下谁来提醒
    nonisolated(unsafe) static var many = false

    var caption: String {
        var bits: [String] = []
        if !when.isEmpty { bits.append(when) }
        if !companion.isEmpty, TodoDTO.many { bits.append(String(localized: "\(companion) 提醒")) }
        if let place { bits.append(placeOn == "leave" ? String(localized: "离开\(place)时") : String(localized: "到\(place)时")) }
        if done {
            bits.append(`repeat` == "week" ? String(localized: "这周做了") : `repeat` == "day" ? String(localized: "今天做了")
                        : String(localized: "做完了"))
        }
        return bits.joined(separator: " · ")
    }
}

struct PlaceDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let lat: Double
    let lon: Double
    let radius: Int
    let inside: Bool?
}

struct TodoRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = PlaceMonitor.shared
    @State private var todos: [TodoDTO] = []
    @State private var places: [PlaceDTO] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: TodoDTO?
    @State private var adding = false
    @State private var showPlaces = false
    @State private var showDone = false

    private var open: [TodoDTO] { todos.filter { !$0.done } }
    private var finished: [TodoDTO] { todos.filter(\.done) }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
                if !places.isEmpty && !monitor.always {
                    Button { askAlways() } label: {
                        Label("「在哪」要「始终允许」定位才提醒得到，点这里打开", systemImage: "location")
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.accentDeep)
                    }
                }
                if loaded && todos.isEmpty {
                    Text("还没有待办。点右上角写一条：做什么、什么时候、在哪，填哪几个都行。")
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                }
                ForEach(open) { row($0) }
                if !finished.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showDone) {
                            ForEach(finished) { row($0) }
                        } label: {
                            Text(String(localized: "做完的 \(finished.count)")).font(Typo.sans(Typo.Size.callout))
                                .foregroundStyle(theme.inkDim)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button { showPlaces = true } label: { Image(systemName: "mappin.and.ellipse") }
                        Button { adding = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $adding) { editor(nil) }
            .sheet(item: $editing) { editor($0) }
            .sheet(isPresented: $showPlaces, onDismiss: { Task { await load() } }) {
                PlacesView().environmentObject(model).environmentObject(theme)
            }
        }
        .environment(\.colorScheme, .light)
        .task { await load() }
    }

    private func editor(_ t: TodoDTO?) -> some View {
        TodoEditor(todo: t, places: places) { await load() }
            .environmentObject(model).environmentObject(theme)
    }

    private func row(_ t: TodoDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { Task { await toggle(t) } } label: {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                    .font(Typo.icon(20)).foregroundStyle(t.done ? theme.accentDeep : theme.inkDim)
            }
            .buttonStyle(.plain)
            Button { editing = t } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.what).font(Typo.sans(Typo.Size.body)).foregroundStyle(t.done ? theme.inkDim : theme.ink)
                        .strikethrough(t.done && t.repeat == "once")
                    if !t.caption.isEmpty {
                        Text(t.caption).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions {
            Button(role: .destructive) { Task { await delete(t) } } label: { Label("删掉", systemImage: "trash") }
        }
    }

    private func askAlways() {
        if monitor.status == .denied || monitor.status == .restricted {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } else {
            UserDefaults.standard.set(true, forKey: "placesWantAlways")
            monitor.askAlways()
        }
    }

    private func load() async {
        TodoDTO.many = model.companions.count > 1
        do {
            todos = try await model.api.call("GET", "todos")
            places = try await model.api.call("GET", "places")
            PlaceMonitor.shared.sync(places)
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func toggle(_ t: TodoDTO) async {
        do {
            let got: TodoDTO = try await model.api.call("POST", "todos/\(t.id)/done", json: ["done": !t.done])
            todos = todos.map { $0.id == got.id ? got : $0 }
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ t: TodoDTO) async {
        do {
            try await model.api.send("DELETE", "todos/\(t.id)")
            todos.removeAll { $0.id == t.id }
        } catch { self.error = error.localizedDescription }
    }
}

/// 写一条 / 改一条：三个格子
struct TodoEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let todo: TodoDTO?
    let places: [PlaceDTO]
    var startDay: Date? = nil              // 从日历某一天点进来的（10-01）：预填成那天
    let saved: () async -> Void

    @State private var what = ""
    @State private var whenKind = "none"          // none / once / daily / weekly
    @State private var day = Date().addingTimeInterval(3600)
    @State private var clock = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var days: Set<Int> = []
    @State private var placeID: Int?
    @State private var placeOn = "arrive"
    @State private var who = ""
    @State private var error: String?
    @State private var busy = false

    private static let week = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        NavigationStack {
            Form {
                Section("做什么") {
                    TextField("买东西、写作业……", text: $what)
                }
                if model.companions.count > 1 {
                    Section {
                        Picker("谁来提醒", selection: $who) {
                            ForEach(model.companions) { c in Text(c.name).tag(c.id.uuidString.lowercased()) }
                        }
                    } footer: { Text("到点 / 到了那儿，由 TA 来找你。") }
                }
                Section {
                    Picker("什么时候", selection: $whenKind) {
                        Text("不填").tag("none")
                        Text("某天").tag("once")
                        Text("每天").tag("daily")
                        Text("每周").tag("weekly")
                    }
                    .pickerStyle(.segmented)
                    switch whenKind {
                    case "once":
                        DatePicker("哪天几点", selection: $day, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    case "daily":
                        DatePicker("几点", selection: $clock, displayedComponents: .hourAndMinute)
                    case "weekly":
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { d in
                                Button { if days.contains(d) { days.remove(d) } else { days.insert(d) } } label: {
                                    Text(Self.week[d]).font(Typo.sans(Typo.Size.callout, .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .background(Circle().fill(days.contains(d) ? theme.accentDeep : theme.inkDim.opacity(0.12)))
                                        .foregroundStyle(days.contains(d) ? Color.white : theme.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        DatePicker("几点", selection: $clock, displayedComponents: .hourAndMinute)
                    default:
                        EmptyView()
                    }
                } header: { Text("什么时候") }
                Section {
                    if places.isEmpty {
                        Text("还没存常去的地方。在待办页右上角的📍里存（站在那儿点「就是这里」，或者在地图上点）。")
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    } else {
                        Picker("在哪", selection: $placeID) {
                            Text("不填").tag(Int?.none)
                            ForEach(places) { p in Text(p.name).tag(Int?.some(p.id)) }
                        }
                        if placeID != nil {
                            Picker("", selection: $placeOn) {
                                Text("到了提醒").tag("arrive")
                                Text("离开时提醒").tag("leave")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                } header: { Text("在哪") } footer: {
                    Text("时间和地方都填：到点时你在那儿才提醒，不在就等你当天到了 / 离开了再提醒。都不填就只是清单上的一条。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(todo == nil ? "写一条" : "改一条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存") { Task { await save() } }
                        .disabled(busy || what.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (whenKind == "weekly" && days.isEmpty))
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear(perform: fill)
    }

    private func fill() {
        who = model.companions.first?.id.uuidString.lowercased() ?? ""
        if todo == nil, let d = startDay {
            whenKind = "once"
            let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
            day = nine > Date() ? nine : Date().addingTimeInterval(3600)
        }
        guard let t = todo else { return }
        who = t.companionId
        what = t.what
        placeID = t.placeId
        placeOn = t.placeOn ?? "arrive"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        if t.shape == "once", let at = t.spec.at, let d = APIClient.parseDate(at) {
            whenKind = "once"; day = d
        } else if t.shape == "at", let time = t.spec.time, let c = hm.date(from: time) {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: c)
            clock = Calendar.current.date(bySettingHour: parts.hour ?? 15, minute: parts.minute ?? 0, second: 0, of: Date()) ?? clock
            let ds = t.spec.days ?? []
            whenKind = ds.isEmpty ? "daily" : "weekly"
            days = Set(ds)
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd HH:mm"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        var body: [String: Any] = ["what": what]
        if !who.isEmpty { body["companion_id"] = who }
        switch whenKind {
        case "once": body["shape"] = "once"; body["spec"] = ["at": f.string(from: day)]
        case "daily": body["shape"] = "at"; body["spec"] = ["time": hm.string(from: clock), "days": [Int]()]
        case "weekly": body["shape"] = "at"; body["spec"] = ["time": hm.string(from: clock), "days": days.sorted()]
        default: body["shape"] = NSNull(); body["spec"] = NSNull()
        }
        body["place_id"] = placeID.map { $0 as Any } ?? NSNull()
        body["place_on"] = placeID == nil ? NSNull() : placeOn
        do {
            if let t = todo {
                _ = try await model.api.raw("PATCH", "todos/\(t.id)", json: body)
            } else {
                _ = try await model.api.raw("POST", "todos", json: body)
            }
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// 常去的地方：存几个（就是这里 / 地图上点），待办里挑
struct PlacesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var places: [PlaceDTO] = []
    @State private var name = ""
    @State private var pin: CLLocationCoordinate2D?
    @State private var radius = 150.0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var locating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if !places.isEmpty {
                    Section("存过的") {
                        ForEach(places) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                Text(String(localized: "方圆 \(p.radius) 米")).font(Typo.sans(Typo.Size.caption))
                                    .foregroundStyle(theme.inkDim)
                            }
                            .swipeActions {
                                Button(role: .destructive) { Task { await delete(p) } } label: { Label("删掉", systemImage: "trash") }
                            }
                        }
                    }
                }
                Section {
                    TextField("名字（学校、家、超市……）", text: $name)
                    Button {
                        Task { await useHere() }
                    } label: {
                        Label(locating ? "正在找你在哪……" : "就是这里（用现在的位置）", systemImage: "location.fill")
                    }
                    .disabled(locating)
                    MapReader { proxy in
                        Map(position: $camera) {
                            if let pin {
                                Marker(name.isEmpty ? String(localized: "这里") : name, coordinate: pin)
                                MapCircle(center: pin, radius: radius).foregroundStyle(theme.accentDeep.opacity(0.18))
                            }
                        }
                        .onTapGesture { p in if let c = proxy.convert(p, from: .local) { pin = c } }
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text(String(localized: "方圆 \(Int(radius)) 米算到了")).font(Typo.sans(Typo.Size.callout))
                        Slider(value: $radius, in: 100...1000, step: 50)
                    }
                    Button("存下来") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || pin == nil)
                } header: { Text("存一个") } footer: {
                    Text("在地图上点一下也能放。手机只告诉 Lumi「到了 / 离开了哪个地方」，不记你走过的路。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("常去的地方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
        }
        .environment(\.colorScheme, .light)
        .task { await load() }
    }

    private func load() async {
        places = (try? await model.api.call("GET", "places")) ?? places
        PlaceMonitor.shared.sync(places)
    }

    private func useHere() async {
        locating = true
        defer { locating = false }
        guard let loc = await PlaceMonitor.shared.here() else {
            error = String(localized: "没拿到位置。去设置里允许 Mele 用定位，或者在地图上点一下。")
            return
        }
        pin = loc.coordinate
        camera = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
        error = nil
    }

    private func save() async {
        guard let pin else { return }
        do {
            let _: PlaceDTO = try await model.api.call("POST", "places", json: [
                "name": name, "lat": pin.latitude, "lon": pin.longitude, "radius": Int(radius)])
            name = ""; self.pin = nil; error = nil
            UserDefaults.standard.set(true, forKey: "placesWantAlways")
            PlaceMonitor.shared.askAlways()
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ p: PlaceDTO) async {
        do {
            try await model.api.send("DELETE", "places/\(p.id)")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}
