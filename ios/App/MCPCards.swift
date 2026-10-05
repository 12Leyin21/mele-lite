import SwiftUI
import WebKit

// MARK: - 接 MCP（10-04 Tilia）
//
// Me →「MCP 服务」：填地址和钥匙，TA 设定里勾能用哪几个。对面是记忆库（mele-memory）时，
// 主屏多一个「记忆库」软件（它的网页，手机版）和「星图」小组件（毛玻璃底 + 自己转的星球）。
// 都只在 Lite 里有：服务列表在手机里的小管家那儿（/mcp/servers），钥匙在钥匙串。

struct MCPServerDTO: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let hasKey: Bool
    let status: String?
    let memory: Bool
    enum CodingKeys: String, CodingKey { case id, name, url, status, memory; case hasKey = "has_key" }
}

private struct MCPTestDTO: Decodable {
    let ok: Bool
    let tools: [String]?
    let memory: Bool?
    let detail: String?
}

private struct MCPWebDTO: Decodable { let base: String; let token: String }

/// 有没有接上记忆库：主屏的「记忆库」软件、「星图」小组件看这个决定灰不灰（拉一次服务列表就更新）
enum MemoryLink {
    static let key = "memory.connected"
    static var connected: Bool { UserDefaults.standard.bool(forKey: key) }

    @discardableResult
    static func refresh(_ api: APIClient) async -> [MCPServerDTO] {
        guard Lite.local else { return [] }
        let list: [MCPServerDTO] = (try? await api.call("GET", "mcp/servers")) ?? []
        UserDefaults.standard.set(list.contains { $0.memory }, forKey: key)
        return list
    }
}

// MARK: - Me 里的卡

struct MCPServersCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var servers: [MCPServerDTO] = []
    @State private var adding = false
    @State private var deleting: MCPServerDTO?
    @State private var tested: [String: String] = [:]   // 服务 id → 试一下的结果
    @State private var testing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP 服务").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            ForEach(servers) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Circle().fill(dotColor(s)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(s.name).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                if s.memory {
                                    Text("记忆库").font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.accentDeep)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(theme.accentSoft.opacity(0.5)))
                                }
                            }
                            Text(statusLine(s)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(1)
                        }
                        Spacer()
                        if testing == s.id { ProgressView().controlSize(.small) } else {
                            Button("试一下") { Task { await test(s) } }
                                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.accentDeep).buttonStyle(.plain)
                        }
                        Button { deleting = s } label: {
                            Image(systemName: "trash").font(Typo.icon(13)).foregroundStyle(theme.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }
                    if let r = tested[s.id] {
                        Text(r).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).padding(.leading, 18)
                    }
                }
            }
            Button { adding = true } label: {
                Label("接一个服务", systemImage: "plus").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.accentDeep)
            }
            .buttonStyle(.plain)
            Text("接上以后，在 TA 的设定里勾上，TA 就能用上面的工具。接的是记忆库的话，TA 每句话都会先去想一下。")
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .task { await load() }
        .sheet(isPresented: $adding) {
            AddMCPServerView { Task { await load() } }
                .environmentObject(model).environmentObject(theme)
                .environment(\.colorScheme, .light)
        }
        .confirmationDialog("不接这个服务了？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("不接了", role: .destructive) {
                if let s = deleting { Task { try? await model.api.send("DELETE", "mcp/servers/\(s.id)"); await load() } }
                deleting = nil
            }
        } message: { Text("TA 们就用不上它的工具了；服务那边存的东西不会删。") }
    }

    private func dotColor(_ s: MCPServerDTO) -> Color {
        s.status == nil ? Color.green.opacity(0.7) : Color.red.opacity(0.75)
    }

    private func statusLine(_ s: MCPServerDTO) -> String {
        switch s.status {
        case "unauthorized": return String(localized: "钥匙不对")
        case "offline": return String(localized: "连不上")
        default: return s.url
        }
    }

    private func load() async { servers = await MemoryLink.refresh(model.api) }

    private func test(_ s: MCPServerDTO) async {
        testing = s.id
        defer { testing = nil }
        guard let r: MCPTestDTO = try? await model.api.call("POST", "mcp/servers/\(s.id)/test") else {
            tested[s.id] = String(localized: "没试成"); return
        }
        if r.ok {
            let names = (r.tools ?? []).joined(separator: "、")
            tested[s.id] = (r.memory == true ? String(localized: "接通了，是记忆库。") : String(localized: "接通了。"))
                + String(localized: "能用：\(names)")
        } else {
            tested[s.id] = r.detail ?? String(localized: "连不上")
        }
        await load()
    }
}

/// 接一个服务：名字、地址、钥匙；存完马上试一下，列出能用的工具
struct AddMCPServerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let onAdded: () -> Void
    @State private var name = String(localized: "记忆库")
    @State private var url = ""
    @State private var token = ""
    @State private var trying = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)
                    TextField("地址（https://…/mcp）", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } footer: {
                    Text("记忆库的地址就是你部署它的网址后面加 /mcp。")
                }
                Section {
                    SecureField("钥匙", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("就是你部署记忆库时的钥匙（MELE_MEMORY_TOKEN）；没自己设过的话，记忆库第一次启动时打在日志里，也存在 data 文件夹的 token 文件里。钥匙只存在这台手机的钥匙串里。")
                }
                if let error {
                    Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
            }
            .navigationTitle("接一个服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if trying { ProgressView() } else {
                        Button("存") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private struct Created: Decodable { let id: String }

    private func save() async {
        trying = true
        defer { trying = false }
        error = nil
        do {
            let c: Created = try await model.api.call("POST", "mcp/servers", json: ["name": name, "url": url, "token": token])
            let r: MCPTestDTO = try await model.api.call("POST", "mcp/servers/\(c.id)/test")
            guard r.ok else {
                // 存下了但没接通：留着让她改，不删
                error = (r.detail ?? String(localized: "连不上")) + String(localized: "（已经存下了，可以在 Me 里删掉重来）")
                onAdded()
                return
            }
            onAdded()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 记忆库的网页（手机版 / 只画星球）

struct MemoryWebView: UIViewRepresentable {
    enum Mode: Equatable { case full(tab: String?), globe }
    let base: String
    let token: String
    let mode: Mode
    /// 只画星球时：不在屏幕上就让网页停下来（省电），回到屏幕上再转
    var paused = false

    final class Coordinator: NSObject, WKNavigationDelegate {
        var paused = false
        func apply(_ web: WKWebView) {
            web.evaluateJavaScript("window.meleGlobePaused = \(paused)", completionHandler: nil)
        }
        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { apply(web) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 钥匙在页面加载前写进 localStorage，网页自己会读（只在这台手机里转一手）
        let literal = (try? JSONSerialization.data(withJSONObject: [token])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        cfg.userContentController.addUserScript(WKUserScript(
            source: "try{localStorage.setItem('mele-memory-token', \(literal)[0])}catch(e){}",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        context.coordinator.paused = paused
        if mode == .globe {
            web.isOpaque = false
            web.backgroundColor = .clear
            web.scrollView.backgroundColor = .clear
            web.scrollView.isScrollEnabled = false
            web.isUserInteractionEnabled = false
        }
        load(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url.map({ !$0.absoluteString.hasPrefix(base) }) ?? true { load(web) }
        if context.coordinator.paused != paused {
            context.coordinator.paused = paused
            context.coordinator.apply(web)
        }
    }

    private func load(_ web: WKWebView) {
        let path: String
        switch mode {
        case .full(let tab): path = "/?embed=1" + (tab.map { "#\($0)" } ?? "")
        case .globe: path = "/?embed=globe"
        }
        if let u = URL(string: base + path) { web.load(URLRequest(url: u)) }
    }
}

/// 「记忆库」软件：整页是记忆库的网页（手机版），钥匙替你填好
struct MemoryRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    var tab: String? = nil
    @State private var servers: [MCPServerDTO] = []
    @State private var picked: String?
    @State private var web: MCPWebDTO?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let web {
                    MemoryWebView(base: web.base, token: web.token, mode: .full(tab: tab)).id(web.base)
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    ContentUnavailableView("连上记忆库才能用", systemImage: "lock.fill",
                                           description: Text("去 Me →「MCP 服务」接一个记忆库。"))
                } else {
                    ProgressView()
                }
            }
            .background(AppBackground())
            .navigationTitle("记忆库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                if servers.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Picker("哪个记忆库", selection: Binding(get: { picked ?? "" }, set: { picked = $0 })) {
                            ForEach(servers) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .task {
            servers = await MemoryLink.refresh(model.api).filter(\.memory)
            picked = servers.first?.id
            if servers.isEmpty { failed = true }
        }
        .task(id: picked) {
            guard let id = picked else { return }
            web = try? await model.api.call("GET", "mcp/servers/\(id)/web")
            failed = web == nil
        }
    }
}

// MARK: - 星图小组件

struct StarmapWidget: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var web: MCPWebDTO?
    @State private var connected = MemoryLink.connected
    @State private var open = false
    @State private var onScreen = true
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.12))
            if let web, connected {
                GeometryReader { g in
                    let side = min(g.size.width, g.size.height)
                    MemoryWebView(base: web.base, token: web.token, mode: .globe, paused: !onScreen || phase != .active || open)
                        .frame(width: side, height: side)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sparkle").font(Typo.icon(26)).foregroundStyle(theme.inkFaint)
                    Label("连上记忆库才能用", systemImage: "lock.fill")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
        }
        .contentShape(Rectangle())
        // 主屏几页横着排、都挂着：滑到别的页就不在屏幕上了
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .global).intersects(CGRect(origin: .zero, size: UIScreen.main.bounds.size))
        } action: { onScreen = $0 }
        .onTapGesture { if connected { open = true } }
        .task {
            let list = await MemoryLink.refresh(model.api)
            connected = list.contains { $0.memory }
            if let s = list.first(where: { $0.memory }) { web = try? await model.api.call("GET", "mcp/servers/\(s.id)/web") }
        }
        .fullScreenCover(isPresented: $open) {
            MemoryRoomView(tab: "graph").environmentObject(model).environmentObject(theme)
        }
    }
}

// MARK: - TA 设定「记性」里：接哪个记忆库、人物卡 / 远事归哪边、能用的 MCP

/// 方案 A（10-04 Tilia）：接上记忆库以后人物卡、远事默认交给它管，各有一个开关；切换时问一句要不要搬。
/// 搬的规矩在小管家里（MemoryMove）：谁是用户写的以谁为准，两边都是用户写的以搬出来那边为准。
struct MemoryLinkRows: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject var store: CompanionSettingsStore
    @State private var servers: [MCPServerDTO] = []
    @State private var change: (body: [String: Any], question: String)?
    @State private var result: String?

    private var memoryServers: [MCPServerDTO] { servers.filter(\.memory) }
    private var otherServers: [MCPServerDTO] { servers.filter { !$0.memory } }
    private var current: String? { store.settings["memory_server"] as? String }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RowPicker(selection: Binding(get: { current ?? "" }, set: { pick($0) })) {
                Text("不接").tag("")
                ForEach(memoryServers) { Text($0.name).tag($0.id) }
            } label: { row("记忆库", memoryServers.isEmpty ? String(localized: "先去 Me →「MCP 服务」接一个") : String(localized: "TA 每句话先去这里想一下")) }
            .disabled(memoryServers.isEmpty && current == nil)
            if current != nil {
                owner("memory_people", String(localized: "人物卡存在"), String(localized: "人物卡"))
                owner("memory_dates", String(localized: "远事存在"), String(localized: "远事"))
            }
            if let result { note(result) }
            if !otherServers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    note(String(localized: "能用的 MCP"))
                    ForEach(otherServers) { s in
                        Toggle(isOn: toolBinding(s.id)) { row(s.name, s.url) }
                    }
                }
            }
        }
        .task { servers = await MemoryLink.refresh(store.api) }
        .confirmationDialog(change?.question ?? "", isPresented: Binding(get: { change != nil }, set: { if !$0 { change = nil } }),
                            titleVisibility: .visible) {
            Button("搬") { apply(move: true) }
            Button("不搬，只换") { apply(move: false) }
            Button("取消", role: .cancel) { change = nil }
        } message: {
            Text("谁是你自己写的就以谁为准；两边都是你写的，以搬出来那边为准。原来那份不删。")
        }
    }

    private func owner(_ key: String, _ title: String, _ what: String) -> some View {
        RowPicker(selection: Binding(get: { store.settings[key] as? String ?? "remote" }, set: { v in
            let toRemote = v == "remote"
            change = ([key == "memory_people" ? "people" : "dates": v],
                      toRemote ? String(localized: "要把手机里的\(what)搬去记忆库吗？") : String(localized: "要把记忆库里的\(what)搬回手机吗？"))
        })) {
            Text("记忆库").tag("remote")
            Text("手机").tag("local")
        } label: { row(title, String(localized: "TA 记\(what)、你在房间里改\(what)，都去这边")) }
    }

    private func pick(_ id: String) {
        guard id != (current ?? "") else { return }
        if id.isEmpty {
            change = (["server": NSNull()], String(localized: "不接记忆库了？要把记忆库里的人物卡和远事搬回手机吗？"))
        } else {
            change = (["server": id, "people": "remote", "dates": "remote"],
                      String(localized: "要把手机里的人物卡和远事搬去记忆库吗？"))
        }
    }

    private struct Moved: Decodable {
        let movedPeople: Int
        let movedDates: Int
        let detail: String?
        enum CodingKeys: String, CodingKey { case detail; case movedPeople = "moved_people"; case movedDates = "moved_dates" }
    }

    private func apply(move: Bool) {
        guard var body = change?.body else { return }
        change = nil
        body["move"] = move
        Task {
            await store.flush()
            let r: Moved? = try? await store.api.call("POST", "\(store.path)/memory", json: body)
            await store.load()
            if let r {
                result = r.detail ?? (move ? String(localized: "搬好了：\(r.movedPeople) 张人物卡、\(r.movedDates) 件远事") : nil)
            } else {
                result = String(localized: "没存上，再试一次")
            }
        }
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { (store.settings["mcp_servers"] as? [String] ?? []).contains(id) }, set: { on in
            var list = store.settings["mcp_servers"] as? [String] ?? []
            list.removeAll { $0 == id }
            if on { list.append(id) }
            store.setNow(settings: ["mcp_servers": list])
        })
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
    }

    private func row(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            note(sub)
        }
    }
}
