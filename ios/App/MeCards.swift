import SwiftUI
import UIKit

// MARK: - 「Me」的几张卡（第二块第 11 步）：我的设定、钥匙串、账号。外观在 MeView.swift。

struct CardTitle: View {
    @EnvironmentObject private var theme: AppTheme
    let text: String
    var body: some View { Text(text).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink) }
}

struct Hint: View {
    @EnvironmentObject private var theme: AppTheme
    let text: String
    var body: some View { Text(text).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
}

/// 我的设定：名字、怎么称呼我、外貌、几点睡几点起
struct ProfileCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var name = ""
    @State private var pronoun = "they"
    @State private var looks = ""
    @State private var sleepFrom = Self.hm("00:00")
    @State private var sleepTo = Self.hm("08:00")
    @State private var saved = false
    @State private var error: String?

    static func hm(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    private func str(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: String(localized: "我的设定"))
            VStack(alignment: .leading, spacing: 6) {
                Hint(text: String(localized: "你叫什么"))
                TextField("名字", text: $name)
                    .font(Typo.sans(Typo.Size.body))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: Radii.chip + 4).fill(Color.white.opacity(0.6)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Hint(text: String(localized: "TA 们提到你时用"))
                Picker("", selection: $pronoun) {
                    Text("她").tag("she")
                    Text("他").tag("he")
                    Text("TA").tag("they")
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Hint(text: String(localized: "你长什么样（可以不写；写了 TA 们就知道）"))
                TextEditor(text: $looks)
                    .font(Typo.sans(Typo.Size.callout))
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Radii.chip + 4).fill(Color.white.opacity(0.6)))
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("几点睡、几点起").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Hint(text: String(localized: "这段时间算深夜，TA 们会收着点"))
                }
                Spacer()
                DatePicker("", selection: $sleepFrom, displayedComponents: .hourAndMinute).labelsHidden()
                Text("–").foregroundStyle(theme.inkDim)
                DatePicker("", selection: $sleepTo, displayedComponents: .hourAndMinute).labelsHidden()
            }
            if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
            Button { Task { await save() } } label: {
                Text(saved ? String(localized: "存好了") : String(localized: "保存"))
                    .font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Capsule().fill(theme.accentDeep))
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .task { await fill() }
    }

    private func fill() async {
        if let p = model.profile { name = p.name; pronoun = p.pronoun; looks = p.looks }
        if let c = model.companions.first,
           let s = (try? await model.api.raw("GET", "companions/\(c.id.lowercased)") as? [String: Any])?["settings"] as? [String: Any] {
            sleepFrom = Self.hm(s["sleep_from"] as? String ?? "00:00")
            sleepTo = Self.hm(s["sleep_to"] as? String ?? "08:00")
        }
    }

    private func save() async {
        do {
            try await model.saveProfile(ProfileDTO(name: name.trimmingCharacters(in: .whitespaces), pronoun: pronoun, looks: looks))
            await model.setSleep(from: str(sleepFrom), to: str(sleepTo))
            error = nil
            withAnimation { saved = true }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { saved = false }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 钥匙串：免费额度进度条、每把钥匙一行、加钥匙
struct KeychainCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var keys: [KeyDTO] = []
    @State private var adding = false
    @State private var deleting: KeyDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: String(localized: "钥匙串"))
            if let trial = model.me?.trial {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("免费额度").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        Spacer()
                        Text("\(Int((trial.ratio * 100).rounded()))%").font(Typo.number(Typo.Size.callout)).foregroundStyle(theme.ink)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.06))
                            Capsule().fill(theme.accentDeep).frame(width: max(6, g.size.width * trial.ratio))
                        }
                    }
                    .frame(height: 8)
                    Hint(text: String(localized: "每天早上 5 点补一些（\(trial.refillAt.formatted(.dateTime.month().day().hour().minute()))）"))
                }
            }
            ForEach(keys) { k in
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").font(Typo.icon(13)).foregroundStyle(theme.accentDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Self.providerName(k.provider)) · \(k.chatModel)").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Text("••••\(k.last4)").font(Typo.number(Typo.Size.caption, .regular)).foregroundStyle(theme.inkFaint)
                    }
                    Spacer()
                    Button { deleting = k } label: {
                        Image(systemName: "trash").font(Typo.icon(13)).foregroundStyle(theme.inkFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { adding = true } label: {
                Label("加一把钥匙", systemImage: "plus").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.accentDeep)
            }
            .buttonStyle(.plain)
            Hint(text: String(localized: "用自己的 key，聊天不限量；钱直接付给模型那家。"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .task { await load() }
        .sheet(isPresented: $adding) {
            AddKeyView { newKey in
                Task { await model.useKeyWhereFree(newKey); await load() }
            }
            .environmentObject(model).environmentObject(theme)
            .environment(\.colorScheme, .light)
        }
        .confirmationDialog("删掉这把钥匙？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let k = deleting { Task { try? await model.api.send("DELETE", "keys/\(k.id)"); await load(); await model.refresh() } }
                deleting = nil
            }
        } message: { Text("用它的联系人会回到免费额度。") }
    }

    private func load() async {
        keys = (try? await model.api.call("GET", "keys")) ?? []
        await model.refreshMe()
    }

    static func providerName(_ p: String) -> String {
        ["deepseek": "DeepSeek", "anthropic": "Claude", "openai": "OpenAI", "gemini": "Gemini",
         "openai-compatible": String(localized: "兼容 OpenAI")][p] ?? p
    }
}

struct ModelDTO: Decodable, Identifiable, Hashable {
    let id: String
    let provider: String
    let label: String
    let priceIn: Double
    let priceOut: Double
    enum CodingKeys: String, CodingKey { case id, provider, label; case priceIn = "price_in"; case priceOut = "price_out" }
}

/// 加钥匙：选哪家 → 贴 key → 选模型（写着多贵）→ 服务器试打一次，通了才存
struct AddKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let onAdded: (String) -> Void
    @State private var provider = "deepseek"
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var models: [ModelDTO] = []
    @State private var chatModel = ""
    @State private var customModel = ""
    @State private var trying = false
    @State private var error: String?

    private let providers = ["deepseek", "anthropic", "openai", "gemini", "openai-compatible"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("哪家", selection: $provider) {
                        ForEach(providers, id: \.self) { Text(KeychainCard.providerName($0)).tag($0) }
                    }
                    SecureField("把 key 贴在这里", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider == "openai-compatible" {
                        TextField("接口地址（https://…/v1）", text: $baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                } footer: {
                    #if LITE
                    Text("key 只存在这台手机的钥匙串里，不经过任何服务器；这里只显示后 4 位。")
                    #else
                    Text("key 加密存在服务器上，谁都看不到原文；这里只显示后 4 位。")
                    #endif
                }

                Section {
                    if models.isEmpty {
                        TextField("模型名", text: $customModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        ForEach(models) { m in
                            Button { chatModel = m.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.label).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                        Text(String(format: String(localized: "每百万 token：输入 $%.2f · 输出 $%.2f"), m.priceIn, m.priceOut))
                                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                                    }
                                    Spacer()
                                    if chatModel == m.id { Image(systemName: "checkmark").foregroundStyle(theme.accentDeep) }
                                }
                            }
                        }
                    }
                } header: { Text("聊天用哪个模型") }

                if let error {
                    Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
            }
            .navigationTitle("加一把钥匙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if trying { ProgressView() } else {
                        Button("存") { Task { await save() } }.disabled(apiKey.count < 8 || pickedModel.isEmpty)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if trying {
                    Text("试一下这把 key…").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Capsule().fill(.regularMaterial))
                        .padding(.bottom, 30)
                }
            }
        }
        .task(id: provider) { await loadModels() }
    }

    private var pickedModel: String { models.isEmpty ? customModel.trimmingCharacters(in: .whitespaces) : chatModel }

    private func loadModels() async {
        models = (try? await model.api.call("GET", "models", query: [URLQueryItem(name: "provider", value: provider)])) ?? []
        chatModel = models.first?.id ?? ""
    }

    private func save() async {
        trying = true
        defer { trying = false }
        var body: [String: Any] = ["provider": provider, "api_key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "chat_model": pickedModel]
        if provider == "openai-compatible" { body["base_url"] = baseURL.trimmingCharacters(in: .whitespaces) }
        do {
            let k: KeyDTO = try await model.api.call("POST", "keys", json: body)
            onAdded(k.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 账号：邮箱、导出、退出登录、删号
struct AccountCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var confirmLogout = false
    @State private var deleting = false
    @State private var deleteWord = ""
    @State private var toured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: String(localized: "账号"))
            if let email = model.me?.email {
                Text(email).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
            }
            Button { Task { await export() } } label: {
                HStack {
                    Label("导出我的数据", systemImage: "square.and.arrow.up").font(Typo.sans(Typo.Size.body))
                    if exporting { ProgressView().padding(.leading, 6) }
                }
                .foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            Button { confirmLogout = true } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right").font(Typo.sans(Typo.Size.body))
                    .foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            Button { CoachTour.arm(); toured = true } label: {
                Label(toured ? String(localized: "好了，去聊天页看看") : String(localized: "重看功能导览"),
                      systemImage: "sparkles").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            Button { deleting = true } label: {
                Label("删除账号", systemImage: "trash").font(Typo.sans(Typo.Size.body)).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .sheet(item: Binding(get: { exportURL.map { ShareItem(url: $0) } }, set: { exportURL = $0?.url })) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { session.logout() }
        } message: { Text("聊天记录都在服务器上，登录回来还在。") }
        .alert("删除账号", isPresented: $deleting) {
            TextField("打「删除」两个字", text: $deleteWord)
            Button("删除", role: .destructive) {
                if deleteWord.trimmingCharacters(in: .whitespaces) == "删除" {
                    Task {
                        try? await model.api.send("DELETE", "me")
                        session.logout(local: true)
                    }
                }
                deleteWord = ""
            }
            Button("算了", role: .cancel) { deleteWord = "" }
        } message: {
            Text("所有联系人、聊天、TA 们记得的事、钥匙都会真删掉，找不回来。确定的话打「删除」两个字。")
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        guard let data = try? await model.api.data("me/export") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-export.json")
        try? data.write(to: url)
        exportURL = url
    }

    struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }
}

/// 系统的分享面板（存到文件、发给自己）
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// TA 们能看到（第三块）：天气、在哪、日程、步数和睡眠四个开关 + 设家 + 快捷指令入口
struct ContextCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var reporter = ContextReporter.shared
    @State private var hook: Hook?
    @State private var showHook = false
    @State private var copied = false

    struct Hook: Decodable { let url: String; let token: String }

    private let rows: [(ContextReporter.Kind, String, String)] = [
        (.weather, "天气", "你那边的天气"),
        (.place, "在哪", "离家 300 米以外才告诉 TA 地名；只在打开 app 时看"),
        (.calendar, "日程", "接下来 3 天有什么事，只看标题和时间"),
        (.health, "步数和睡眠", "今天走了多少、昨晚睡了多久"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TA 们能看到").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            ForEach(rows, id: \.0) { kind, title, sub in
                Toggle(isOn: Binding(get: { reporter.enabled.contains(kind) },
                                     set: { on in Task { await reporter.set(kind, on: on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Text(sub).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                }
                .tint(theme.accentDeep)
                if kind == .place && reporter.enabled.contains(.place) {
                    HStack {
                        Text(reporter.homeSet ? String(localized: "家已经设好了") : String(localized: "还没设家，先设了才会报"))
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                        Spacer()
                        Button(reporter.homeSet ? String(localized: "重设为这里") : String(localized: "把这里设为家")) {
                            Task { await reporter.setHomeHere() }
                        }
                        .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                    }
                    .padding(.leading, 4)
                }
            }
            if !Lite.local { shortcut }     // 快捷指令要一个网址收，手机里的小管家没有（连着 Host 就有）
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder private var shortcut: some View {
            Divider()
            Button { Task { await loadHook(); withAnimation { showHook.toggle() } } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("快捷指令").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        Text("自己的快捷指令往这里报一句（「在健身房」），TA 们就知道").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                    Spacer()
                    Image(systemName: showHook ? "chevron.up" : "chevron.down").font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
                }
            }
            .buttonStyle(.plain)
            if showHook, let hook {
                VStack(alignment: .leading, spacing: 6) {
                    Text("网址").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    Text(hook.url).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink).textSelection(.enabled)
                    Text("口令（放在请求头 Authorization: Bearer 后面）").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    Text(hook.token).font(Typo.number(Typo.Size.callout, .regular)).foregroundStyle(theme.ink).textSelection(.enabled)
                    Text("内容：{\"text\": \"在健身房\"}，或者直接一句话").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    HStack(spacing: 16) {
                        Button(copied ? String(localized: "复制好了") : String(localized: "复制口令")) {
                            UIPasteboard.general.string = hook.token
                            copied = true
                        }
                        Button(String(localized: "换一个口令")) { Task { await resetHook() } }
                    }
                    .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                }
            }
    }

    private func loadHook() async {
        if hook == nil { hook = try? await model.api.call("GET", "me/hook") }
    }

    private func resetHook() async {
        hook = try? await model.api.call("POST", "me/hook/reset")
        copied = false
    }
}
