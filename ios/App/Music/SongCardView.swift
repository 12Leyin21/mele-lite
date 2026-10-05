import SwiftUI
import MusicKit

/// 歌卡（09-30）。移植自之前自用的 App MusicCard（Tilia：移植自之前自用的 App的，好看）：封面糊开当底、毛玻璃盖一层，卡上只有歌；
/// 它那句话跟之前自用的 App一样，是卡下面一个普通气泡（ChatView 里画）。
/// ▶︎：连了 Apple Music 的用「音乐」放整首（没订阅就退回试听），没连的放 30 秒试听；「在 XX 打开 ↗」按 TA 选的平台。
/// 歌词不做（Tilia 09-30：收费上架的 App 放第三方歌词有版权风险）。
struct SongCardView: View {
    let song: SongCardData
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var music = MusicStore.shared
    @Environment(\.openURL) private var openURL
    @StateObject private var preview = PreviewPlayer()
    @State private var whole = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                AsyncImage(url: song.artwork.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.3).overlay(Image(systemName: "music.note").foregroundStyle(AppTheme.inkFaint))
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(Typo.accent(15, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(Typo.sans(11.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    if let url = music.platform.link(for: song) {
                        Button { openURL(url) } label: {
                            Text("\(music.platform.title) ↗")
                                .font(Typo.sans(11, .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 4)
                Button { Task { await play() } } label: {
                    Image(systemName: preview.isPlaying || whole ? "pause.circle.fill" : "play.circle.fill")
                        .font(Typo.icon(32))
                        .foregroundStyle(theme.accent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            if preview.isPlaying || preview.progress > 0 {
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.4))
                            Capsule().fill(theme.accent).frame(width: max(4, geo.size.width * preview.progress))
                        }
                    }
                    .frame(height: 4)
                    Text("\(preview.timeText) / 0:30")
                        .font(Typo.number(10, .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: 260)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background {
            ZStack {
                if let art = song.artwork, let url = URL(string: art) {
                    AsyncImage(url: url) { phase in
                        (phase.image ?? Image(systemName: "circle.fill")).resizable().scaledToFill()
                    }
                    .blur(radius: 34)
                    .overlay(Color.black.opacity(0.28))
                } else {
                    Color.black.opacity(0.25)
                }
            }
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .onDisappear { preview.stop() }
    }

    private func play() async {
        if whole {                                   // 整首在「音乐」里放着：再点 = 暂停
            SystemMusicPlayer.shared.pause()
            whole = false
            return
        }
        if !preview.isPlaying, music.appleLinked, await music.playWhole(song) {
            whole = true
            return
        }
        if let p = song.preview, let url = URL(string: p) { preview.toggle(url: url) }
        else if let url = music.platform.link(for: song) { openURL(url) }
    }
}
