import SwiftUI

/// 音乐房间（09-30）：今日私选 · 一起听 · 歌单 · 设置。UI 先移植自之前自用的 App（Tilia 09-30），统一调 UI 时再改。
struct MusicRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var music = MusicStore.shared
    @State private var listening = false

    private var aiName: String { model.primaryCompanion?.name ?? "Lumi" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let e = music.error {                     // 连不上的原因放最上面，一眼看得到（09-30）
                        Text(e).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.red.opacity(0.85))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if music.link?.platform == nil {
                        pickPlatform
                    } else {
                        picksSection
                        if music.appleLinked {
                            Button { listening = true } label: {
                                Label(String(localized: "一起听"), systemImage: "headphones")
                                    .font(Typo.sans(Typo.Size.headline, .semibold))
                                    .foregroundStyle(theme.accentDeep)
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .cardSurface(radius: 16)
                            }
                            .buttonStyle(.plain)
                        }
                        shelfSection
                        settingsSection
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 60)
            }
            .navigationTitle(String(localized: "音乐"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .task {
                music.api = model.api
                await music.loadAll()
            }
            .fullScreenCover(isPresented: $listening) {
                ListenTogetherView().environmentObject(model).environmentObject(theme)
            }
        }
    }

    // MARK: 第一次进来：你用什么听歌

    private var pickPlatform: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "你平时用什么听歌？"))
                .font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            Text(String(localized: "连上 Apple Music，\(aiName)就知道你最近在听什么，每天早上还会给你挑几首。用别的平台也行，歌卡上会有「在 XX 打开」。"))
                .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            ForEach(MusicPlatform.allCases) { p in
                Button { Task { await music.choose(p) } } label: {
                    HStack {
                        Text(p.title).font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                        Spacer()
                        if p == .apple && music.busy { ProgressView() }
                        else { Image(systemName: "chevron.right").foregroundStyle(theme.inkDim) }
                    }
                    .padding(16).cardSurface(radius: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: 今日私选（移植自之前自用的 App DailyPicksSheet）

    private var picksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "今日私选")).font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
                Text(String(localized: "\(aiName)挑给你的、你没听过的歌")).font(Typo.sans(12.5)).foregroundStyle(theme.inkDim)
            }
            if music.picks.isEmpty {
                Text((music.link?.picks_n ?? 0) == 0 ? String(localized: "每日私选关着。下面「设置」里可以打开。")
                     : Lite.on ? String(localized: "今天还没挑——过了推歌时间、你打开 App 的时候\(aiName)就会挑，挑好了在聊天里发给你。")
                     : String(localized: "今天还没挑——早上候选备好，\(aiName)醒来就会挑，挑好了在聊天里发给你。"))
                    .font(Typo.sans(14)).foregroundStyle(theme.inkDim).padding(.vertical, 12)
            }
            ForEach($music.picks) { $pick in
                PickRow(pick: $pick, aiName: aiName)
            }
        }
    }

    // MARK: 歌单

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "歌单")).font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            if music.shelf.isEmpty {
                Text(String(localized: "\(aiName)发给你的歌、私选里的歌都会收在这里。"))
                    .font(Typo.sans(14)).foregroundStyle(theme.inkDim)
            }
            ForEach(music.shelf) { s in
                ShelfRow(song: s)
            }
        }
    }

    // MARK: 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "设置")).font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            VStack(spacing: 0) {
                Menu {
                    ForEach(MusicPlatform.allCases) { p in
                        Button(p.title) { Task { await music.choose(p) } }
                    }
                } label: {
                    settingRow(String(localized: "我用什么听歌"), value: music.platform.title + (music.appleLinked ? " ✓" : ""))
                }
                Divider()
                Stepper(value: Binding(get: { music.link?.picks_n ?? 3 },
                                       set: { n in Task { await music.setPicks(count: n) } }), in: 0...5) {
                    Text((music.link?.picks_n ?? 3) == 0 ? String(localized: "每日私选：不推")
                         : String(localized: "每日私选：每天 \(music.link?.picks_n ?? 3) 首"))
                        .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                }
                .padding(.vertical, 12)
                Divider()
                PicksTimeRow(value: music.link?.picks_at ?? "") { at in Task { await music.setPicks(at: at) } }
                if Lite.on {            // 歌词（10-05 Tilia）：默认不拿，自己开；Host 和本机（10-05 夜）都有
                    Divider()
                    Toggle(isOn: Binding(get: { music.link?.lyrics ?? false }, set: { on in Task { await music.setLyrics(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("歌词").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                            Text(Lite.hosted ? String(localized: "打开后，你的 Host 会去 lrclib（大家共建的歌词库）拿歌词，\(aiName) 能跟着你听到哪一句。只管以后新听的歌。")
                                 : String(localized: "打开后，手机会去 lrclib（大家共建的歌词库）拿你正在放的歌的歌词，\(aiName) 能跟着你听到哪一句。只对苹果自带的「音乐」App 有效。"))
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .cardSurface(radius: 16)
            if music.platform == .apple && !music.appleLinked {
                // 没连上（多半是没有会员，09-30）：说清楚现在能用什么、不能用什么
                VStack(alignment: .leading, spacing: 8) {
                    Text(Lite.on ? String(localized: "还没给 Mele「媒体与 Apple Music」的权限。现在这样也能用：")
                                 : String(localized: "Apple Music 还没连上（多半是没有会员）。现在这样也能用："))
                        .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                    Text(String(localized: "· 歌卡能试听 30 秒，一点就跳进 Apple Music 那一首\n· 每日私选照样推，按你投的票和 \(aiName) 记得的挑\n· 放不了整首，\(aiName) 也不知道你正在听什么（「一起听」要会员）"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { Task { await music.connectApple() } } label: {
                        Text(String(localized: "开通了会员？再连一次")).font(Typo.sans(Typo.Size.body, .semibold))
                    }
                    .padding(.top, 2)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(radius: 16)
            }
        }
    }

    private func settingRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            Spacer()
            Text(value).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
        }
        .padding(.vertical, 12)
    }
}

/// 几点推：默认「起床后半小时」，也可以自己定一个点
private struct PicksTimeRow: View {
    let value: String
    let save: (String) -> Void
    @EnvironmentObject private var theme: AppTheme
    @State private var custom = false
    @State private var time = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { custom || !value.isEmpty }, set: { on in
                custom = on
                save(on ? Self.hm(time) : "")
            })) {
                Text(String(localized: "自己定推歌时间")).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            }
            if custom || !value.isEmpty {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: time) { _, t in save(Self.hm(t)) }
            } else {
                Text(String(localized: "现在是起床后半小时")).font(Typo.sans(12.5)).foregroundStyle(theme.inkDim)
            }
        }
        .padding(.vertical, 12)
        .onAppear {
            if !value.isEmpty, let d = Self.parse(value) { time = d }
        }
    }

    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func parse(_ s: String) -> Date? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date())
    }
}

/// 私选的一行：封面 + 歌名 + 三颗键（多来点 / 无感 / 少来点）+ 为什么；点了喜欢 / 不喜欢出五颗星和一行「为什么」
private struct PickRow: View {
    @Binding var pick: DailyPick
    let aiName: String
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var music = MusicStore.shared
    @Environment(\.openURL) private var openURL
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: pick.artwork)) { phase in
                    (phase.image ?? Image(systemName: "music.note")).resizable().scaledToFill()
                        .foregroundStyle(theme.inkDim)
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(pick.name).font(Typo.sans(16, .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                    Text(pick.artist).font(Typo.sans(13)).foregroundStyle(theme.inkDim).lineLimit(1)
                }
                Spacer(minLength: 6)
                voteButton("up", icon: "hand.thumbsup")
                voteButton("meh", icon: "minus")
                voteButton("down", icon: "hand.thumbsdown")
            }
            Text(pick.why).font(Typo.sans(14.5)).foregroundStyle(theme.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !pick.vote.isEmpty { feedback }
        }
        .padding(14)
        .cardSurface(radius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            Task {
                if await music.playWhole(pick.song) { return }
                if let url = music.platform.link(for: pick.song) { openURL(url) }
            }
        }
    }

    private func voteButton(_ value: String, icon: String) -> some View {
        let on = pick.vote == value
        return Button {
            let next = on ? "" : value
            if next != pick.vote { pick.stars = 0 }
            if next.isEmpty { pick.reason = "" }
            pick.vote = next
            Task { await music.vote(pick, next) }
        } label: {
            Image(systemName: on && value != "meh" ? icon + ".fill" : icon)
                .font(Typo.icon(14, .medium))
                .foregroundStyle(on ? .white : theme.ink.opacity(0.75))
                .frame(width: 32, height: 32)
                .background(on ? theme.accentDeep : theme.ink.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pick.vote == "up" || pick.vote == "down" {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            let next = pick.stars == n ? 0 : n
                            pick.stars = next
                            Task { await music.vote(pick, pick.vote, stars: next) }
                        } label: {
                            Image(systemName: n <= pick.stars ? "star.fill" : "star")
                                .foregroundStyle(n <= pick.stars ? (pick.vote == "up" ? theme.accentDeep : theme.ink) : theme.inkDim)
                                .font(Typo.icon(17)).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(caption).font(Typo.sans(12)).foregroundStyle(theme.inkDim).padding(.leading, 4)
                }
            }
            TextField("", text: $pick.reason, prompt: Text(prompt), axis: .vertical)
                .font(Typo.sans(13.5)).foregroundStyle(theme.ink)
                .lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: pick.reason) { _, text in       // 打字停下 1 秒就存（照之前自用的 App）
                    saveTask?.cancel()
                    let p = pick
                    saveTask = Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if !Task.isCancelled { await music.vote(p, p.vote, reason: text) }
                    }
                }
        }
    }

    private var caption: String {
        if pick.stars == 0 { return pick.vote == "up" ? String(localized: "有多喜欢？") : String(localized: "有多不喜欢？") }
        return pick.vote == "up"
            ? ["", "还行", "喜欢", "很喜欢", "特别喜欢", "非常喜欢"][pick.stars]
            : ["", "有点不喜欢", "不喜欢", "挺不喜欢", "很不喜欢", "非常不喜欢"][pick.stars]
    }

    private var prompt: String {
        switch pick.vote {
        case "up": return String(localized: "为什么喜欢？（\(aiName)下次挑歌会看到）")
        case "down": return String(localized: "为什么不喜欢？（\(aiName)下次挑歌会看到）")
        default: return String(localized: "为什么无感？（\(aiName)下次挑歌会看到）")
        }
    }
}

private struct ShelfRow: View {
    let song: ShelfSong
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var music = MusicStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            Task {
                if await music.playWhole(song.song) { return }
                if let url = music.platform.link(for: song.song) { openURL(url) }
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: song.artwork)) { phase in
                    (phase.image ?? Image(systemName: "music.note")).resizable().scaledToFill().foregroundStyle(theme.inkDim)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).font(Typo.sans(15, .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                    Text(song.why.isEmpty ? song.artist : "\(song.artist) · \(song.why)")
                        .font(Typo.sans(12.5)).foregroundStyle(theme.inkDim).lineLimit(1)
                }
                Spacer()
                if song.source == "pick" {
                    Text(String(localized: "私选")).font(Typo.sans(10.5, .semibold)).foregroundStyle(theme.accentDeep)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accentDeep.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
