import SwiftUI

/// 注册引导（第二块第 12 步）：三页，每页一个问题，都有默认值，最快十秒就能开始聊。
/// 1 你叫什么 + 怎么称呼你 → 2 你们是什么关系（可跳过）→ 3 TA 什么时候可以来找你（四档带价钱 + 几点睡几点起）
/// 做完进 Lumi 的聊天，它先开口（/greet，不扣免费额度），然后放功能导览。
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var page = 0
    @State private var name = ""
    @State private var pronoun = "they"
    @State private var relationship = ""
    @State private var customRel = ""
    @State private var level = "mid"
    @State private var sleepFrom = ProfileCard.hm("00:00")
    @State private var sleepTo = ProfileCard.hm("08:00")
    @State private var estimate: EstimateDTO?
    @State private var saving = false
    @State private var addingKey = false
    @State private var keyAdded = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var lumi: CompanionDTO? { model.companions.first }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 0) {
                dots.padding(.top, 20)
                Spacer(minLength: 20)
                Group {
                    switch page {
                    case 0: namePage
                    case 1: relationshipPage
                    #if LITE
                    default: keyPage
                    #else
                    default: patrolPage
                    #endif
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                Spacer(minLength: 20)
                if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red).padding(.bottom, 8) }
                bottomBar
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .environment(\.colorScheme, .light)
        .task {
            if let lumi {
                estimate = try? await model.api.call("GET", "companions/\(lumi.id.lowercased)/patrol/estimate")
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule().fill(i == page ? theme.accentDeep : theme.inkFaint.opacity(0.4))
                    .frame(width: i == page ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: page)
    }

    private func title(_ accent: String, _ question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(accent).font(Typo.accent(Typo.Size.largeTitle)).foregroundStyle(theme.ink)
            Text(question).font(Typo.sans(Typo.Size.headline)).foregroundStyle(theme.inkDim)
        }
        .padding(.bottom, 24)
    }

    // 1
    private var namePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Hello", String(localized: "你叫什么？"))
            TextField("名字", text: $name)
                .font(Typo.sans(Typo.Size.headline))
                .focused($nameFocused)
                .submitLabel(.next)
                .onSubmit { if canNext { go(1) } }
                .padding(14)
                .cardSurface(radius: Radii.control)
            VStack(alignment: .leading, spacing: 8) {
                Text("提到你的时候用").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                Picker("", selection: $pronoun) {
                    Text("她").tag("she")
                    Text("他").tag("he")
                    Text("TA").tag("they")
                }
                .pickerStyle(.segmented)
            }
            .padding(.top, 6)
        }
        .onAppear { nameFocused = true }
    }

    // 2
    private var relationshipPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Us", String(localized: "你们是什么关系？"))
            FlowChips(items: [("friend", "朋友"), ("partner", "恋人"), ("family", "家人"), ("buddy", "搭子")],
                      selected: [relationship]) { id in
                relationship = relationship == id ? "" : id
                customRel = ""
            }
            TextField("或者自己写", text: $customRel)
                .font(Typo.sans(Typo.Size.body))
                .padding(12)
                .cardSurface(radius: Radii.control)
                .onChange(of: customRel) { _, v in if !v.isEmpty { relationship = "" } }
            Text("之后都能改。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
        }
    }

    // 3
    #if LITE
    /// Lite 第三页：接上你自己的模型（Lite 没有服务器，TA 用你的 key 直接从手机说话）
    private var keyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Key").font(Typo.accent(Typo.Size.largeTitle)).foregroundStyle(theme.ink)
            Text("TA 用哪家的模型说话？").font(Typo.sans(Typo.Size.headline)).foregroundStyle(theme.inkDim)
            Text("Mele Lite 没有服务器：你的 key 只存在这台手机的钥匙串里，TA 直接从手机连模型。DeepSeek 最省，Claude 最会聊。")
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            Button { addingKey = true } label: {
                HStack {
                    Image(systemName: keyAdded ? "checkmark.circle.fill" : "key.fill")
                    Text(keyAdded ? "钥匙加好了" : "加一把钥匙")
                }
                .font(Typo.sans(Typo.Size.body, .semibold))
                .foregroundStyle(keyAdded ? theme.accentDeep : .white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Capsule().fill(keyAdded ? Color.white.opacity(0.7) : theme.accent))
            }
            .buttonStyle(.plain)
            Text("没有也可以先跳过，之后在 Me →「钥匙串」里加。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
        }
        .sheet(isPresented: $addingKey) {
            AddKeyView { _ in keyAdded = true }
                .environmentObject(model).environmentObject(theme)
        }
    }
    #endif

    private var patrolPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Say hi", String(localized: "TA 什么时候可以来找你？"))
            ForEach([("low", "偶尔"), ("mid", "时不时"), ("high", "常常"), ("max", "黏人")], id: \.0) { key, label in
                Button { level = key } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(Typo.sans(Typo.Size.body, level == key ? .semibold : .regular)).foregroundStyle(theme.ink)
                            Text(priceLine(key)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                        Spacer()
                        if level == key { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accentDeep) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .cardSurface(radius: Radii.bubble, strength: level == key ? 1.3 : 0.8)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("你一般几点睡、几点起").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                Spacer()
                DatePicker("", selection: $sleepFrom, displayedComponents: .hourAndMinute).labelsHidden()
                Text("–").foregroundStyle(theme.inkDim)
                DatePicker("", selection: $sleepTo, displayedComponents: .hourAndMinute).labelsHidden()
            }
            .padding(.top, 4)
            Text("睡着的时候 TA 会收着点。这些之后都能改。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
        }
    }

    private func priceLine(_ key: String) -> String {
        guard let l = estimate?.levels?[key] else { return "" }
        if let usd = l.usdPerMonth { return String(format: String(localized: "一个月最多 %d 次 · 约 $%.2f"), l.wakesPerMonth, usd) }
        return String(localized: "一个月最多 \(l.wakesPerMonth) 次")
    }

    private var canNext: Bool { page != 0 || !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var bottomBar: some View {
        HStack {
            if page > 0 {
                Button { go(page - 1) } label: {
                    Image(systemName: "chevron.left").font(Typo.icon(16, .semibold)).foregroundStyle(theme.inkDim)
                        .frame(width: 48, height: 48).capsuleSurface()
                }
                .buttonStyle(.plain)
            }
            if page == 1 {
                Button("跳过") { relationship = ""; customRel = ""; go(2) }
                    .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).padding(.leading, 8)
            }
            Spacer()
            Button { if page < 2 { go(page + 1) } else { Task { await finish() } } } label: {
                Text(page < 2 ? String(localized: "下一步") : (saving ? "…" : String(localized: "开始")))
                    .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 32).padding(.vertical, 14)
                    .background(Capsule().fill(theme.accentDeep))
            }
            .buttonStyle(.plain)
            .disabled(!canNext || saving)
            .opacity(canNext ? 1 : 0.5)
        }
    }

    private func go(_ p: Int) {
        nameFocused = false
        withAnimation(.snappy(duration: 0.35)) { page = p }
    }

    private func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func finish() async {
        saving = true
        defer { saving = false }
        do {
            let rel = customRel.trimmingCharacters(in: .whitespaces).isEmpty ? relationship : customRel.trimmingCharacters(in: .whitespaces)
            if let lumi {
                _ = try await model.api.raw("PATCH", "companions/\(lumi.id.lowercased)", json: ["settings": [
                    "relationship": rel, "patrol_level": level, "sleep_from": hm(sleepFrom), "sleep_to": hm(sleepTo),
                    "tz": TimeZone.current.identifier]])
            }
            CoachTour.arm()
            model.greetPending = true
            // 名字存上以后，外面就从引导换成主页（RootView 看 profile.name）
            try await model.saveProfile(ProfileDTO(name: name.trimmingCharacters(in: .whitespaces), pronoun: pronoun, looks: ""))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
