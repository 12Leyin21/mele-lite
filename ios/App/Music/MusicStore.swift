import SwiftUI
import MusicKit
import AVFoundation
import MediaPlayer

/// 音乐房间的数据（09-30，plans/2026-09-30-music.md 第 8～10 步）。
/// 连接 Apple Music 走 MusicKit：手机拿用户凭证交给服务器，服务器替 TA 查「最近在听」、准备每日私选。
/// 别的平台（网易云 / QQ 音乐 / Spotify）只做「在 XX 打开」的跳转。

extension Notification.Name {
    static let lumiOpenMusic = Notification.Name("LumiOpenMusic")
    /// 它点的歌（歌卡带 queue）：一起听页开着就排进「音乐」的播放队列
    static let lumiSongQueued = Notification.Name("LumiSongQueued")
}

struct MusicLinkInfo: Decodable, Equatable {
    let platform: String?
    let linked: Bool
    let storefront: String
    let picks_n: Int
    let picks_at: String
    var lyrics: Bool?          // Mele Host 的歌词开关（10-05）；本机 / 老服务器没有
}

struct DailyPick: Decodable, Identifiable, Equatable {
    let pos: Int
    let song_id: String
    let name: String
    let artist: String
    let artwork: String
    let preview: String
    let url: String
    let why: String
    var vote: String
    var stars: Int
    var reason: String
    var id: Int { pos }
    var song: SongCardData { SongCardData(id: song_id, name: name, artist: artist, artwork: artwork, preview: preview, url: url, why: why) }
}

struct ShelfSong: Decodable, Identifiable {
    let id: Int
    let song_id: String
    let name: String
    let artist: String
    let artwork: String
    let preview: String
    let url: String
    let source: String
    let why: String
    var song: SongCardData { SongCardData(id: song_id, name: name, artist: artist, artwork: artwork, preview: preview, url: url, why: why) }
}

enum MusicPlatform: String, CaseIterable, Identifiable {
    case apple, netease, qq, spotify, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Music"
        case .netease: return String(localized: "网易云音乐")
        case .qq: return String(localized: "QQ 音乐")
        case .spotify: return "Spotify"
        case .other: return String(localized: "其他")
        }
    }

    /// 歌卡上「在 XX 打开」：Apple Music 直接开那首；别的平台开那个 App 里对这首的搜索
    func link(for song: SongCardData) -> URL? {
        let q = "\(song.name) \(song.artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch self {
        case .apple, .other: return song.url.flatMap(URL.init(string:))
        case .netease: return URL(string: "https://music.163.com/#/search/m/?s=\(q)&type=1")
        case .qq: return URL(string: "https://y.qq.com/n/ryqq/search?w=\(q)")
        case .spotify: return URL(string: "https://open.spotify.com/search/\(q)")
        }
    }
}

@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()
    var api: APIClient?

    @Published var link: MusicLinkInfo?
    @Published var picks: [DailyPick] = []
    @Published var shelf: [ShelfSong] = []
    @Published var error: String?
    @Published var busy = false

    var platform: MusicPlatform { MusicPlatform(rawValue: link?.platform ?? "") ?? .apple }
    /// Lite（本机和连 Host 都是）不交凭证给服务器，Host 回的 linked 永远是 false：看手机自己给没给「媒体与 Apple Music」权限（10-05 夜）
    var appleLinked: Bool {
        link?.platform == "apple" && (Lite.on ? MPMediaLibrary.authorizationStatus() == .authorized : link?.linked == true)
    }

    func loadAll() async {
        await load()
        await loadPicks()
        await loadShelf()
    }

    func load() async {
        link = try? await api?.call("GET", "me/music", as: MusicLinkInfo.self)
    }

    func loadPicks() async {
        picks = (try? await api?.call("GET", "music/picks", query: [URLQueryItem(name: "day", value: FoodStore.today())],
                                      as: [DailyPick].self)) ?? []
    }

    func loadShelf() async {
        shelf = (try? await api?.call("GET", "music/shelf", as: [ShelfSong].self)) ?? []
    }

    /// 选听歌平台。Apple Music 要先授权、拿用户凭证（服务器会问一次「你在哪个区」验真）
    func choose(_ p: MusicPlatform) async {
        error = nil
        if p == .apple { await connectApple(); return }
        do { link = try await api?.call("PUT", "me/music", json: ["platform": p.rawValue], as: MusicLinkInfo.self) }
        catch let e as APIError { error = e.message } catch { self.error = String(localized: "没连上服务器，过会儿再试") }
    }

    /// 连 Apple Music。连不上（没授权 / 没会员 / 苹果不给凭证）也照样选上 Apple Music，只是不带凭证：
    /// 歌卡能试听、一点跳进 Apple Music，私选照推（09-30：Tilia的会员过期了，不能因为这个整个用不了）
    func connectApple() async {
        busy = true
        defer { busy = false }
        if Lite.on {                                 // Lite：只要「媒体与 Apple Music」的权限，不要凭证（10-04）
            guard await MusicAuthorization.request() == .authorized else {
                error = String(localized: "没拿到 Apple Music 的授权。可以在「设置 → Mele」里打开「媒体与 Apple Music」")
                await chooseAppleWithoutToken()
                return
            }
            await chooseAppleWithoutToken()
            ContextReporter.shared.reportMusicNow()
            return
        }
        guard await MusicAuthorization.request() == .authorized else {
            error = String(localized: "没拿到 Apple Music 的授权。可以在「设置 → Mele」里打开「媒体与 Apple Music」")
            await chooseAppleWithoutToken()
            return
        }
        if let sub = try? await MusicSubscription.current, !sub.canPlayCatalogContent {
            await chooseAppleWithoutToken()          // 没会员：不去要凭证，页面上写着能用什么
            return
        }
        let provider = DefaultMusicTokenProvider()
        let dev: String
        do { dev = try await provider.developerToken(options: .ignoreCache) }
        catch { self.error = Self.explain(error, step: "① 开发者凭证"); await chooseAppleWithoutToken(); return }
        let user: String
        do { user = try await provider.userToken(for: dev, options: .ignoreCache) }
        catch { self.error = Self.explain(error, step: "② 你的 Apple Music 凭证"); await chooseAppleWithoutToken(); return }
        do {
            link = try await api?.call("PUT", "me/music", json: ["platform": "apple", "user_token": user], as: MusicLinkInfo.self)
            ContextReporter.shared.reportMusicNow()
        } catch let e as APIError {
            error = "③ 服务器验证：\(e.message)"
            await chooseAppleWithoutToken()
        } catch {
            self.error = "③ 服务器验证：\(error.localizedDescription)"
            await chooseAppleWithoutToken()
        }
    }

    /// 只存「用 Apple Music」+ 在哪个区（手机自己知道，私选按这个区找歌）
    private func chooseAppleWithoutToken() async {
        var body: [String: Any] = ["platform": "apple"]
        if let cc = try? await MusicDataRequest.currentCountryCode { body["storefront"] = cc }
        else if let region = Locale.current.region?.identifier { body["storefront"] = region.lowercased() }
        link = (try? await api?.call("PUT", "me/music", json: body, as: MusicLinkInfo.self)) ?? link
    }

    /// 苹果给的错翻成人话（09-30 Tilia真机没连上：先知道卡在哪一步）
    static func explain(_ error: Error, step: String) -> String {
        if let e = error as? MusicTokenRequestError {
            switch e {
            case .privacyAcknowledgementRequired:
                return "\(step)：要先打开一次手机自带的「音乐」App，同意里面的隐私说明，再回来连"
            case .userNotSignedIn:
                return "\(step)：手机上还没登录 Apple 账户的媒体服务（设置 → 你的名字 → 媒体与购买项目）"
            case .permissionDenied:
                return "\(step)：没拿到权限，去「设置 → Mele」打开「媒体与 Apple Music」"
            case .developerTokenRequestFailed:
                return "\(step)：苹果没发开发者凭证（App ID 的 MusicKit 可能还没生效）"
            case .userTokenRequestFailed:
                return "\(step)：苹果没发你的 Apple Music 凭证（可能要先开通 / 登录 Apple Music）"
            case .userTokenRevoked:
                return "\(step)：之前的授权被收回了，再连一次"
            case .unknown:
                return "\(step)：苹果说不知道哪里错了（\(error)）"
            @unknown default:
                return "\(step)：\(error)"
            }
        }
        return "\(step)：\(error.localizedDescription)"
    }

    func disconnect() async {
        try? await api?.send("DELETE", "me/music")
        link = nil
    }

    func setLyrics(_ on: Bool) async {
        do { link = try await api?.call("PATCH", "me/music", json: ["lyrics": on], as: MusicLinkInfo.self) }
        catch let e as APIError { error = e.message } catch {}
    }

    func setPicks(count: Int? = nil, at: String? = nil) async {
        var body: [String: Any] = [:]
        if let count { body["picks_n"] = count }
        if let at { body["picks_at"] = at }
        do { link = try await api?.call("PATCH", "me/music", json: body, as: MusicLinkInfo.self) }
        catch let e as APIError { error = e.message } catch {}
    }

    func vote(_ pick: DailyPick, _ value: String, stars: Int? = nil, reason: String? = nil) async {
        var body: [String: Any] = ["vote": value]
        if let stars { body["stars"] = stars }
        if let reason { body["reason"] = reason }
        try? await api?.send("POST", "music/picks/\(FoodStore.today())/\(pick.pos)/vote", json: body)
    }

    // MARK: 放歌（连了 Apple Music 的）

    /// 用「音乐」App 放整首；没订阅 / 出错返回 false（歌卡退回试听）
    func playWhole(_ song: SongCardData) async -> Bool {
        if Lite.on {                                 // 系统播放器按商店编号放（不用开发者凭证；没订阅会放不出来）
            guard appleLinked else { return false }
            let p = MPMusicPlayerController.systemMusicPlayer
            p.setQueue(with: [song.id])
            do { try await p.prepareToPlay() } catch { return false }
            p.play()
            return true
        }
        guard appleLinked, let s = await catalogSong(song.id) else { return false }
        do {
            SystemMusicPlayer.shared.queue = [s]
            try await SystemMusicPlayer.shared.play()
            return true
        } catch { return false }
    }

    func enqueue(_ song: SongCardData) async -> Bool {
        if Lite.on {
            guard appleLinked else { return false }
            MPMusicPlayerController.systemMusicPlayer.prepend(MPMusicPlayerStoreQueueDescriptor(storeIDs: [song.id]))
            return true
        }
        guard appleLinked, let s = await catalogSong(song.id) else { return false }
        do {
            try await SystemMusicPlayer.shared.queue.insert(s, position: .afterCurrentEntry)
            return true
        } catch { return false }
    }

    private func catalogSong(_ id: String) async -> Song? {
        var req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        req.limit = 1
        return try? await req.response().items.first
    }
}

/// 30 秒试听（Apple 的官方试听片段，不用订阅）。移植自之前自用的 App MusicCard 的 PreviewPlayer
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var timeText = "0:00"

    private var player: AVPlayer?
    private var observer: Any?

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let player = AVPlayer(url: url)
            self.player = player
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 10),
                                                      queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, let item = self.player?.currentItem else { return }
                    let duration = item.duration.seconds
                    let current = time.seconds
                    guard duration.isFinite, duration > 0 else { return }
                    self.progress = current / duration
                    self.timeText = String(format: "%d:%02d", Int(current) / 60, Int(current) % 60)
                    if current >= duration - 0.3 {
                        self.player?.seek(to: .zero)
                        self.player?.pause()
                        self.isPlaying = false
                        self.progress = 0
                    }
                }
            }
        }
        player?.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        player = nil
        observer = nil
        isPlaying = false
    }
}
