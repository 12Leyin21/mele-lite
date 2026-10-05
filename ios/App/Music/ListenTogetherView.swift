import SwiftUI
import MusicKit

/// 一起听（09-30）。移植自之前自用的 App MusicTogetherView（去掉歌词和 Spotify 那套）：模糊封面当背景、两个头像挂着耳机线「一起听了 X 分钟」、
/// 遥控「音乐」App（声音从「音乐」出，这里是遥控器兼观景台）。页开着时：换歌报给服务器（它知道你在听什么）；
/// 它点的歌（歌卡带 queue）排进播放队列，页上说一声。
struct ListenTogetherView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = SystemMusicPlayer.shared.state
    @ObservedObject private var queue = SystemMusicPlayer.shared.queue
    @State private var openedAt = Date()
    @State private var lastReported = ""
    @State private var toast: String?

    static var isOpen = false

    private var current: Song? {
        if case .song(let s) = queue.currentEntry?.item { return s }
        return nil
    }

    private var aiName: String { model.primaryCompanion?.name ?? "Lumi" }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.24), Color(red: 0.09, green: 0.10, blue: 0.14)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if let art = current?.artwork?.url(width: 600, height: 600) {
                GeometryReader { geo in
                    AsyncImage(url: art) { phase in
                        (phase.image ?? Image(systemName: "circle.fill")).resizable().scaledToFill()
                    }
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
                    .blur(radius: 64).overlay(Color.black.opacity(0.52))
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 18) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(Typo.icon(18, .semibold)).foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Text(String(localized: "一起听")).font(Typo.accent(17)).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Color.clear.frame(width: 18, height: 18)
                    }
                    .padding(.horizontal, 22).padding(.top, 8)
                    togetherLine(now: ctx.date)
                    Spacer(minLength: 2)
                    if let s = current {
                        AsyncImage(url: s.artwork?.url(width: 600, height: 600)) { phase in
                            (phase.image ?? Image(systemName: "music.note")).resizable().scaledToFill()
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(width: 280, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                        VStack(spacing: 5) {
                            Text(s.title).font(Typo.accent(20)).foregroundStyle(.white).lineLimit(1)
                            Text(s.artistName).font(Typo.sans(14)).foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.horizontal, 30)
                        HStack(spacing: 34) {
                            control("backward.end.fill", 24) { try? await SystemMusicPlayer.shared.skipToPreviousEntry() }
                            control(state.playbackStatus == .playing ? "pause.circle.fill" : "play.circle.fill", 64) {
                                if state.playbackStatus == .playing { SystemMusicPlayer.shared.pause() }
                                else { try? await SystemMusicPlayer.shared.play() }
                            }
                            control("forward.end.fill", 24) { try? await SystemMusicPlayer.shared.skipToNextEntry() }
                        }
                        Text(String(localized: "\(aiName)也听着这首"))
                            .font(Typo.sans(11.5)).foregroundStyle(.white.opacity(0.35))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "music.note.house").font(Typo.icon(44)).foregroundStyle(.white.opacity(0.35))
                            Text(String(localized: "「音乐」没在放歌\n去放一首，这里就活了"))
                                .font(Typo.sans(14)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(height: 292)
                    }
                    Spacer()
                }
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast).font(Typo.sans(13, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: current?.id)
        .preferredColorScheme(.dark)
        .onAppear { Self.isOpen = true; openedAt = Date(); report() }
        .onDisappear { Self.isOpen = false }
        .onChange(of: current?.id) { _, _ in report() }
        .onChange(of: state.playbackStatus) { _, _ in report() }
        .onReceive(NotificationCenter.default.publisher(for: .lumiSongQueued)) { note in
            guard let song = note.userInfo?["song"] as? SongCardData else { return }
            Task {
                let ok = await MusicStore.shared.enqueue(song)
                withAnimation { toast = ok ? String(localized: "\(aiName)点了一首：\(song.name)") : nil }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation { toast = nil }
            }
        }
    }

    // MARK: 两个头像 + 耳机线（移植自之前自用的 App 09-08 Tilia定稿：两股不相连，各自从耳塞向内飘落、渐变淡出）

    private func togetherLine(now: Date) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                EarphoneStrands()
                    .stroke(LinearGradient(stops: [.init(color: .white.opacity(0.65), location: 0.28),
                                                   .init(color: .white.opacity(0), location: 0.96)],
                                           startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 220, height: 116)
                HStack(spacing: -8) {
                    Group {
                        if let c = model.primaryCompanion { CompanionAvatar(companion: c, size: 56) }
                        else { placeholder }
                    }
                    .overlay(alignment: .leading) { earbud.rotationEffect(.degrees(-18)).offset(x: -4.5, y: 8) }
                    placeholder
                        .shadow(color: .black.opacity(0.4), radius: 5, x: -2)
                        .overlay(alignment: .trailing) { earbud.rotationEffect(.degrees(18)).offset(x: 4.5, y: 8) }
                }
            }
            .frame(height: 116)
            Text(String(localized: "一起听了 \(max(1, Int(now.timeIntervalSince(openedAt) / 60))) 分钟"))
                .font(Typo.sans(12.5)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var placeholder: some View {
        Circle().fill(.white.opacity(0.15))
            .overlay { Image(systemName: "person.fill").font(Typo.icon(13)).foregroundStyle(.white.opacity(0.6)) }
            .frame(width: 56, height: 56)
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
    }

    private var earbud: some View {
        Capsule().fill(.white.opacity(0.92)).frame(width: 6, height: 13).shadow(color: .black.opacity(0.35), radius: 1.5)
    }

    private func control(_ icon: String, _ size: CGFloat, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: icon).font(Typo.icon(size)).foregroundStyle(.white.opacity(0.92))
        }
        .buttonStyle(.plain)
    }

    /// 换歌 / 暂停就报给服务器（进〔TA 那边〕，它知道你在听什么）
    private func report() {
        guard let s = current else { return }
        let playing = state.playbackStatus == .playing
        let key = "\(s.id.rawValue)|\(playing)"
        guard key != lastReported else { return }
        lastReported = key
        Task {
            try? await model.api.send("POST", "music/now", json: ["song_id": s.id.rawValue, "name": s.title,
                                                                   "artist": s.artistName, "playing": playing,
                                                                   "position_s": SystemMusicPlayer.shared.playbackTime])
        }
    }
}

private struct EarphoneStrands: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let budY = rect.height * 0.34, endY = rect.height * 0.94
        path.move(to: CGPoint(x: rect.midX - 57, y: budY))
        path.addCurve(to: CGPoint(x: rect.midX - 13, y: endY),
                      control1: CGPoint(x: rect.midX - 67, y: budY + 36), control2: CGPoint(x: rect.midX - 32, y: endY - 12))
        path.move(to: CGPoint(x: rect.midX + 57, y: budY))
        path.addCurve(to: CGPoint(x: rect.midX + 13, y: endY),
                      control1: CGPoint(x: rect.midX + 67, y: budY + 36), control2: CGPoint(x: rect.midX + 32, y: endY - 12))
        return path
    }
}
