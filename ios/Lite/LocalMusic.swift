#if LITE
import Foundation
import MediaPlayer
import MeleLiteCore

/// 音乐（10-04 Tilia：App 开着能不能跑——能跑这一版）：照 server/api/routes_music.py + music/*.py 搬进手机。
/// - 不用 Apple 的开发者凭证（Lite 的包名不一定开了 MusicKit）：找歌走 iTunes 搜索接口（编号就是 Apple Music 的编号），
///   「TA 常听谁」读手机音乐资料库的播放次数，放歌 / 在听什么走系统播放器。
/// - 每日私选：服务器是早上醒来推；Lite 没有一直醒着的东西，改成**过了推歌时间、第一次打开 App 时**推。
///   程序先找真歌（种子歌手的热门 + 模型报的风格相近的歌手，曲库搜得到才算），它只从池子里挑，挑完发进聊天（带歌卡）。
/// - 〔在听〕给歌名和歌手；开了歌词（默认关，10-05 夜）再给此刻唱到的两句。服务器那版的「耳朵」（量节奏、真听一遍）这里没有。
enum LocalMusic {
    static let poolLimit = 30
    static let perArtist = 3
    static let picksDefault = 3
    static let whyMax = 120
    static let reasonMax = 200
    static let blockScore = -3
    static let keepDays = 30
    static let nowFresh: TimeInterval = 20 * 60
    static let listenFresh: TimeInterval = 10 * 60
    static let zhStorefronts: Set<String> = ["cn", "hk", "tw", "mo", "sg"]

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts
        let s = host.store
        switch (r.method, p.first ?? "", p.count) {
        case ("GET", "me", 2) where p[1] == "music": return .json(view(s))
        case ("PUT", "me", 2) where p[1] == "music":
            let platform = r.json["platform"] as? String ?? ""
            guard ["apple", "netease", "qq", "spotify", "other"].contains(platform) else { return .error(400, String(localized: "不认识这个听歌平台")) }
            var sf = (r.json["storefront"] as? String ?? "").lowercased()
            if sf.count != 2 { sf = (Locale.current.region?.identifier ?? "us").lowercased() }
            var l = link(s) ?? ["picks_n": picksDefault, "picks_at": ""]
            l["platform"] = platform; l["storefront"] = sf
            s.write("music-link.json", l)
            return .json(view(s))
        case ("PATCH", "me", 2) where p[1] == "music":
            guard var l = link(s) else { return .error(400, String(localized: "先选你用什么听歌")) }
            if let n = r.json["picks_n"] as? Int {
                guard (0...5).contains(n) else { return .error(400, String(localized: "每天 0~5 首")) }
                l["picks_n"] = n
            }
            if let at = r.json["picks_at"] as? String {
                guard at.isEmpty || parseHM(at) != nil else { return .error(400, String(localized: "时间写成 HH:MM")) }
                l["picks_at"] = at
            }
            if let on = r.json["lyrics"] as? Bool { l["lyrics"] = on }
            s.write("music-link.json", l)
            if r.json["lyrics"] as? Bool == true, let d = s.read("music-now.json") as? [String: Any] { fetchLyrics(s, d) }   // 开了就把正在放的那首先拿上
            return .json(view(s))
        case ("DELETE", "me", 2) where p[1] == "music":
            try? FileManager.default.removeItem(at: s.root.appendingPathComponent("music-link.json"))
            return .empty
        case ("GET", "music", 2) where p[1] == "shelf":
            return .json(s.collection("music-shelf").sorted { LocalStore.date($0["created_at"]) > LocalStore.date($1["created_at"]) }.prefix(200).map { $0 })
        case ("GET", "music", 2) where p[1] == "picks":
            maybePick(host)
            let day = r.query["day"].flatMap { $0.isEmpty ? nil : $0 } ?? LocalBooks.today()
            return .json(picksOn(s, day))
        case ("POST", "music", 5) where p[1] == "picks" && p[4] == "vote":
            guard let pos = Int(p[3]), let got = vote(s, day: p[2], pos: pos, r.json["vote"] as? String ?? "",
                                                      stars: r.json["stars"] as? Int, reason: r.json["reason"] as? String) else {
                return .error(404, String(localized: "没有这一首"))
            }
            return .json(got)
        case ("POST", "music", 2) where p[1] == "now":
            let name = (r.json["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .error(400, String(localized: "歌名是空的")) }
            var now: [String: Any] = ["song_id": r.json["song_id"] as? String ?? "", "name": String(name.prefix(200)),
                                      "artist": String((r.json["artist"] as? String ?? "").prefix(200)),
                                      "playing": r.json["playing"] as? Bool ?? false, "at": LocalStore.iso(Date())]
            // 放到第几秒、整首多长（10-05 夜：歌词跟着唱到哪一句）
            if let pos = r.json["position_s"] as? Double, pos >= 0, pos < 36_000 { now["position_s"] = pos }
            if let dur = r.json["duration_s"] as? Double, dur > 0, dur < 36_000 { now["duration_s"] = dur }
            s.write("music-now.json", now)
            if now["playing"] as? Bool == true { fetchLyrics(s, now) }
            return .empty
        case ("GET", "music", 3) where p[1] == "song": return .needsHost       // 歌卡已经带全了，不会走到这
        default: return nil
        }
    }

    // MARK: - 连接

    static func link(_ s: LocalStore) -> [String: Any]? { s.read("music-link.json") as? [String: Any] }

    /// linked：Lite 里 = 选了 Apple Music 且给了「媒体与 Apple Music」权限（不再要凭证）
    static func view(_ s: LocalStore) -> [String: Any] {
        guard let l = link(s) else { return ["platform": NSNull(), "linked": false, "storefront": "", "picks_n": 0, "picks_at": ""] }
        let apple = (l["platform"] as? String) == "apple"
        return ["platform": l["platform"] ?? NSNull(), "linked": apple && MPMediaLibrary.authorizationStatus() == .authorized,
                "storefront": l["storefront"] ?? "", "picks_n": l["picks_n"] ?? picksDefault, "picks_at": l["picks_at"] ?? "",
                "lyrics": l["lyrics"] as? Bool ?? false]
    }

    static func storefront(_ s: LocalStore) -> String {
        let sf = (link(s)?["storefront"] as? String ?? "").lowercased()
        return sf.count == 2 ? sf : (Locale.current.region?.identifier ?? "us").lowercased()
    }

    static func parseHM(_ s: String) -> (Int, Int)? {
        let xs = s.split(separator: ":").compactMap { Int($0) }
        guard xs.count == 2, (0..<24).contains(xs[0]), (0..<60).contains(xs[1]) else { return nil }
        return (xs[0], xs[1])
    }

    // MARK: - 〔在听〕

    static func nowLine(_ s: LocalStore, zh: Bool) -> String {
        guard let d = s.read("music-now.json") as? [String: Any] else { return "" }
        let at = LocalStore.date(d["at"])
        guard Date().timeIntervalSince(at) <= nowFresh, let name = d["name"] as? String, !name.isEmpty else { return "" }
        let artist = d["artist"] as? String ?? ""
        let song = zh ? "《\(name)》" + (artist.isEmpty ? "" : "- \(artist)") : "\"\(name)\"" + (artist.isEmpty ? "" : " by \(artist)")
        if d["playing"] as? Bool ?? false {
            let pair = lyricPair(s, d)
            if !pair.isEmpty {                       // 开了歌词：唱到的那句和它前一句（照服务器 ears._lyric_pair）
                return zh ? "〔在听〕TA 在听\(song)，此刻唱到：\n" + pair.joined(separator: "\n")
                          : "〔Listening〕They're listening to \(song), right now at:\n" + pair.joined(separator: "\n")
            }
            return zh ? "〔在听〕TA 在听\(song)。" : "〔Listening〕They're listening to \(song)."
        }
        let mins = max(1, Int(Date().timeIntervalSince(at) / 60))
        return zh ? "〔在听〕TA 刚才在听\(song)（\(mins) 分钟前）。" : "〔Listening〕They were listening to \(song) (\(mins) min ago)."
    }

    // MARK: - 歌词（10-05 夜Tilia：Lite 也要；照 server/music/ears.py 的 lrclib）
    // 默认关，TA 在音乐设置里自己开。开了：手机直接问 lrclib（大家共建的歌词库，不要钥匙）拿带时间轴的词，
    // 按系统播放器报的「放到第几秒」+ 报完过了多久，算出此刻唱到哪两句。只对苹果「音乐」App 有效（别的 App 读不到）。

    static let lrclib = "https://lrclib.net/api"
    static let endSlack = 5.0                  // 位置超过时长 5 秒 = 这首已经放完了
    static let lyricsKeep = 40
    static let retryAfter: TimeInterval = 86_400   // 没找到的歌一天后再试
    nonisolated(unsafe) private static var fetching: Set<String> = []
    private static let fetchLock = NSLock()

    static func lyricsOn(_ s: LocalStore) -> Bool { link(s)?["lyrics"] as? Bool ?? false }

    private static func lyricsKey(_ d: [String: Any]) -> String {
        let id = d["song_id"] as? String ?? ""
        return id.isEmpty ? "name:\(d["name"] ?? "")|\(d["artist"] ?? "")" : id
    }

    /// 「[01:02.30] 一句」→ [(62.3, "一句")]，按时间排；一行多个时间戳各算一次；空词跳过
    static func parseLRC(_ text: String) -> [(Double, String)] {
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            let line = re.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            guard !ms.isEmpty, !line.isEmpty else { continue }
            for m in ms {
                let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
                out.append(((t * 100).rounded() / 100, line))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// 唱到的那句和它前一句；还没到第一句 = []
    static func pair(_ lyrics: [(Double, String)], at pos: Double) -> [String] {
        guard let idx = lyrics.lastIndex(where: { $0.0 <= pos }) else { return [] }
        return idx > 0 ? [lyrics[idx - 1].1, lyrics[idx].1] : [lyrics[idx].1]
    }

    private static func lyricPair(_ s: LocalStore, _ d: [String: Any]) -> [String] {
        guard lyricsOn(s), let pos0 = d["position_s"] as? Double,
              let hit = (s.read("music-lyrics.json") as? [String: [String: Any]])?[lyricsKey(d)],
              let rows = hit["lines"] as? [[Any]], !rows.isEmpty else { return [] }
        let lyrics = rows.compactMap { r -> (Double, String)? in
            guard r.count == 2, let t = (r[0] as? Double) ?? (r[0] as? Int).map(Double.init), let l = r[1] as? String else { return nil }
            return (t, l)
        }
        let pos = pos0 + Date().timeIntervalSince(LocalStore.date(d["at"]))
        if let dur = d["duration_s"] as? Double, pos > dur + endSlack { return [] }
        return pair(lyrics, at: pos)
    }

    /// 开着歌词、在放、这首还没拿过（或者一天前没找到）：后台去 lrclib 拿，存进 music-lyrics.json（最多留 40 首）
    static func fetchLyrics(_ s: LocalStore, _ d: [String: Any]) {
        guard lyricsOn(s), let name = d["name"] as? String, !name.isEmpty else { return }
        let key = lyricsKey(d)
        if let old = (s.read("music-lyrics.json") as? [String: [String: Any]])?[key],
           !((old["lines"] as? [Any])?.isEmpty ?? true) || Date().timeIntervalSince(LocalStore.date(old["at"])) < retryAfter { return }
        guard fetchLock.withLock({ fetching.insert(key).inserted }) else { return }
        let artist = d["artist"] as? String ?? ""
        let dur = Int((d["duration_s"] as? Double ?? 0).rounded())
        Task {
            defer { _ = fetchLock.withLock { fetching.remove(key) } }
            let lyrics = await lrclibFetch(name: name, artist: artist, duration: dur)
            var all = s.read("music-lyrics.json") as? [String: [String: Any]] ?? [:]
            all[key] = ["lines": lyrics.map { [$0.0, $0.1] as [Any] }, "at": LocalStore.iso(Date())]
            if all.count > lyricsKeep {
                for k in all.keys.sorted(by: { LocalStore.date(all[$0]?["at"]) < LocalStore.date(all[$1]?["at"]) }).prefix(all.count - lyricsKeep) {
                    all[k] = nil
                }
            }
            s.write("music-lyrics.json", all)
        }
    }

    /// 先精确取，再搜索（时长差 3 秒以内、有带时间的词）。都没有 = []
    static func lrclibFetch(name: String, artist: String, duration: Int) async -> [(Double, String)] {
        func get(_ path: String, _ q: [String: String]) async -> Any? {
            var c = URLComponents(string: "\(lrclib)/\(path)")!
            c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = c.url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("Mele Lite (https://github.com/12Leyin21/mele-lite)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        var q = ["track_name": name, "artist_name": artist]
        if duration > 0 { q["duration"] = String(duration) }
        if let hit = await get("get", q) as? [String: Any], let lrc = hit["syncedLyrics"] as? String, !lrc.isEmpty {
            return parseLRC(lrc)
        }
        for hit in await get("search", ["track_name": name, "artist_name": artist]) as? [[String: Any]] ?? [] {
            guard let lrc = hit["syncedLyrics"] as? String, !lrc.isEmpty else { continue }
            if duration > 0, abs((hit["duration"] as? Double ?? 0) - Double(duration)) > 3 { continue }
            return parseLRC(lrc)
        }
        return []
    }

    // MARK: - 曲库（iTunes 搜索接口）

    struct Song {
        var id: String, name: String, artist: String, album: String, artwork: String, preview: String, url: String
        var dict: [String: Any] { ["id": id, "name": name, "artist": artist, "album": album, "artwork": artwork, "preview": preview, "url": url] }
    }

    private static func get(_ path: String, _ q: [String: String]) async -> [[String: Any]] {
        var c = URLComponents(string: "https://itunes.apple.com/\(path)")!
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url, let (d, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return j["results"] as? [[String: Any]] ?? []
    }

    private static func song(_ x: [String: Any]) -> Song? {
        guard (x["wrapperType"] as? String) == "track", let id = x["trackId"] as? Int else { return nil }
        let art = (x["artworkUrl100"] as? String ?? "").replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return Song(id: String(id), name: x["trackName"] as? String ?? "", artist: x["artistName"] as? String ?? "",
                    album: x["collectionName"] as? String ?? "", artwork: art, preview: x["previewUrl"] as? String ?? "",
                    url: x["trackViewUrl"] as? String ?? "")
    }

    static func searchSongs(_ q: String, sf: String, limit: Int = 8) async -> [Song] {
        await get("search", ["term": q, "entity": "song", "limit": "\(limit)", "country": sf]).compactMap(song)
    }

    static func topSongs(of artist: String, sf: String, limit: Int) async -> [Song] {
        guard let a = await get("search", ["term": artist, "entity": "musicArtist", "limit": "1", "country": sf]).first,
              let aid = a["artistId"] as? Int else { return [] }
        // 按歌手编号认（歌手名会对不上：搜出来叫「周杰倫」，歌上署名是 Jay Chou）；合辑、别人的歌不算
        return await get("lookup", ["id": "\(aid)", "entity": "song", "limit": "\(limit)", "country": sf])
            .filter { ($0["artistId"] as? Int) == aid }.compactMap(song)
    }

    /// TA 用中文、那个区只有英文名（比如澳洲的《晴天》叫 Sunny Day）：同编号去香港区借中文名，繁体转简体
    /// （服务器借的是新加坡区，但 iTunes 搜索接口在新加坡区只给英文名，10-04 试过）
    static func altNames(_ ids: [String], sf: String, zh: Bool) async -> [String: Song] {
        guard zh, !zhStorefronts.contains(sf), !ids.isEmpty else { return [:] }
        let hans = StringTransform("Hant-Hans")
        var out: [String: Song] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            for var x in await get("lookup", ["id": chunk.joined(separator: ","), "country": "hk"]).compactMap(song) {
                x.name = x.name.applyingTransform(hans, reverse: false) ?? x.name
                x.artist = x.artist.applyingTransform(hans, reverse: false) ?? x.artist
                out[x.id] = x
            }
        }
        return out
    }

    // MARK: - 纯逻辑（照 music/picks.py）

    static func songKey(_ name: String, _ artist: String) -> String {
        let raw = "\(name)|\(artist)".lowercased()
        return String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "|" }.map(Character.init).prefix(160))
    }

    static func splitArtists(_ s: String) -> [String] {
        s.replacingOccurrences(of: #"\s*(?:[、,，/]|&| feat\. | ft\. )\s*"#, with: "\u{1}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func voteWeight(_ v: String, _ stars: Int) -> Int {
        (["up": 1, "down": -1][v] ?? 0) * (stars >= 5 ? 2 : 1)
    }

    private static let coverish = try! NSRegularExpression(pattern: "(伴奏|钢琴版|鋼琴版|翻唱|cover|karaoke|instrumental|piano ver|lofi|sped up|slowed|8d audio)", options: .caseInsensitive)
    private static let variant = try! NSRegularExpression(pattern: #"\s*[\(\[（【-].*?(live|remaster|version|edit|mix|acoustic|demo|现场|版).*$"#, options: .caseInsensitive)

    static func isCoverish(_ s: String) -> Bool { coverish.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }

    static func baseTitle(_ s: String) -> String {
        variant.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 按权重抽种子歌手（不是每天都拿前八）
    static func seedArtists(played: [(String, Int)], scores: [String: Int], n: Int = 8) -> [String] {
        var weight: [String: Double] = [:], display: [String: String] = [:]
        func add(_ name: String, _ w: Double) {
            let k = name.lowercased()
            if display[k] == nil { display[k] = name }
            weight[k, default: 0] += w
        }
        for (artists, plays) in played { for a in splitArtists(artists) { add(a, 1 + Double(min(max(1, plays), 10)) * 0.5) } }
        for (k, v) in scores where v > 0 { add(k, Double(2 * v)) }
        var pool = weight.keys.filter { (scores[$0] ?? 0) > blockScore }
        var out: [String] = []
        while !pool.isEmpty && out.count < n {
            var r = Double.random(in: 0..<pool.reduce(0) { $0 + weight[$1]! })
            for (i, k) in pool.enumerated() {
                r -= weight[k]!
                if r <= 0 { out.append(display[k]!); pool.remove(at: i); break }
            }
        }
        return out
    }

    static func buildPool(_ cands: [(Song, String)], heard: Set<String>, recentIDs: Set<String>, scores: [String: Int]) -> [(Song, String)] {
        var seenTitles = Set<String>(), per: [String: Int] = [:], kept: [(Song, String)] = []
        for (c, origin) in cands {
            guard !c.id.isEmpty, !recentIDs.contains(c.id), !isCoverish(c.name), !heard.contains(songKey(c.name, c.artist)) else { continue }
            let names = splitArtists(c.artist)
            guard !names.contains(where: { (scores[$0.lowercased()] ?? 0) <= blockScore }) else { continue }
            let lead = (names.first ?? "").lowercased()
            let key = baseTitle(c.name) + "|" + lead
            guard !seenTitles.contains(key), per[lead, default: 0] < perArtist else { continue }
            seenTitles.insert(key); per[lead, default: 0] += 1
            kept.append((c, origin))
        }
        let familiar = kept.filter { $0.1 == "familiar" }.shuffled(), fresh = kept.filter { $0.1 != "familiar" }.shuffled()
        let wantFam = min(familiar.count, max(poolLimit / 3, poolLimit - fresh.count))
        return (Array(familiar.prefix(wantFam)) + Array(fresh.prefix(poolLimit - wantFam))).shuffled()
    }

    static func parseArtistList(_ text: String, limit: Int = 12) -> [String] {
        guard let a = text.firstIndex(of: "["), let z = text.lastIndex(of: "]"), a < z,
              let items = try? JSONSerialization.jsonObject(with: Data(text[a...z].utf8)) as? [Any] else { return [] }
        var out: [String] = [], seen = Set<String>()
        for x in items {
            let n = String("\(x)".trimmingCharacters(in: .whitespaces).prefix(60))
            if !n.isEmpty, !seen.contains(n.lowercased()) { seen.insert(n.lowercased()); out.append(n) }
        }
        return Array(out.prefix(limit))
    }

    // MARK: - 歌单 / 私选 / 投票

    static func shelve(_ s: LocalStore, _ x: Song, source: String, why: String) {
        var all = s.collection("music-shelf")
        guard !all.contains(where: { ($0["song_id"] as? String) == x.id }) else { return }
        all.append(["id": s.nextID("music-shelf"), "song_id": x.id, "name": x.name, "artist": x.artist, "artwork": x.artwork,
                    "preview": x.preview, "url": x.url, "source": source, "why": why, "created_at": LocalStore.iso(Date())])
        s.saveCollection("music-shelf", all)
    }

    static func picksOn(_ s: LocalStore, _ day: String) -> [[String: Any]] {
        s.collection("music-picks").filter { ($0["day"] as? String) == day }.sorted { ($0["pos"] as? Int ?? 0) < ($1["pos"] as? Int ?? 0) }
            .map { var x = $0; x.removeValue(forKey: "day"); return x }
    }

    static func scores(_ s: LocalStore) -> [String: Int] { s.read("music-votes.json") as? [String: Int] ?? [:] }

    static func vote(_ s: LocalStore, day: String, pos: Int, _ v: String, stars: Int?, reason: String?) -> [String: Any]? {
        guard ["up", "meh", "down", ""].contains(v) else { return nil }
        var all = s.collection("music-picks")
        guard let i = all.firstIndex(where: { ($0["day"] as? String) == day && ($0["pos"] as? Int) == pos }) else { return nil }
        let oldV = all[i]["vote"] as? String ?? "", oldS = all[i]["stars"] as? Int ?? 0
        var newS = stars.map { max(0, min(5, $0)) } ?? (v == oldV ? oldS : 0)
        if !["up", "down"].contains(v) { newS = 0 }
        let delta = voteWeight(v, newS) - voteWeight(oldV, oldS)
        all[i]["vote"] = v; all[i]["stars"] = newS
        if v.isEmpty { all[i]["reason"] = "" }
        else if let reason { all[i]["reason"] = String(reason.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(reasonMax)) }
        s.saveCollection("music-picks", all)
        if delta != 0 {
            var sc = scores(s)
            for a in splitArtists(all[i]["artist"] as? String ?? "") {
                sc[a.lowercased(), default: 0] += delta
                if sc[a.lowercased()] == 0 { sc.removeValue(forKey: a.lowercased()) }
            }
            s.write("music-votes.json", sc)
        }
        var out = all[i]; out.removeValue(forKey: "day")
        return out
    }

    // MARK: - 每日私选（打开 App 时，过了推歌时间、今天还没推就推）

    nonisolated(unsafe) private static var picking = false
    private static let lock = NSLock()

    static func pickTime(_ s: LocalStore) -> Date? {
        guard let l = link(s), (l["picks_n"] as? Int ?? picksDefault) > 0 else { return nil }
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        if let at = l["picks_at"] as? String, let (h, m) = parseHM(at) {
            return cal.date(bySettingHour: h, minute: m, second: 0, of: today)
        }
        let wake = (s.companions.first?["settings"] as? [String: Any])?["sleep_to"] as? String ?? "08:00"
        let (h, m) = parseHM(wake) ?? (8, 0)
        return cal.date(bySettingHour: h, minute: m, second: 0, of: today)?.addingTimeInterval(30 * 60)
    }

    static func maybePick(_ host: LocalHost) {
        let s = host.store
        let day = LocalBooks.today()
        guard let at = pickTime(s), Date() >= at, (s.read("music-picked.json") as? String) != day else { return }
        guard lock.withLock({ () -> Bool in if picking { return false }; picking = true; return true }) else { return }
        Task.detached {
            defer { lock.withLock { picking = false } }
            if await makePicks(host, day: day) { s.write("music-picked.json", day) }
        }
    }

    /// 它那个联系人：第一个（服务器也是给账号第一个联系人开推歌的钟）
    private static func mainCompanion(_ host: LocalHost) -> ([String: Any], ProviderConfig, String)? {
        guard let c = host.store.companions.first, let (p, k) = host.route(for: c), !LiteConsent.book.needsAsk(p) else { return nil }
        return (c, p, k)
    }

    private static func ask(_ provider: ProviderConfig, _ key: String, system: String, _ prompt: String, maxTokens: Int = 600) async -> String {
        var cfg = provider
        cfg.thinking = false
        let req = ChatRequest(system: system, turns: [ChatTurn(role: .user, text: prompt)], maxTokens: maxTokens)
        var text = ""
        do { for try await e in makeClient(cfg, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { return "" }
        return text
    }

    /// 手机资料库里最近两个月放过的：[(歌手, 次数)] + 听过的歌（不再推）
    static func libraryHistory() -> (played: [(String, Int)], heard: Set<String>) {
        guard MPMediaLibrary.authorizationStatus() == .authorized, let items = MPMediaQuery.songs().items else { return ([], []) }
        let since = Date().addingTimeInterval(-60 * 86400)
        var played: [String: Int] = [:], heard = Set<String>()
        for it in items where it.playCount > 0 {
            heard.insert(songKey(it.title ?? "", it.artist ?? ""))
            if let d = it.lastPlayedDate, d >= since, let a = it.artist, !a.isEmpty { played[a, default: 0] += it.playCount }
        }
        return (played.sorted { $0.value > $1.value }.prefix(30).map { ($0.key, $0.value) }, heard)
    }

    static func makePicks(_ host: LocalHost, day: String) async -> Bool {
        let s = host.store
        guard let (comp, provider, key) = mainCompanion(host) else { return false }
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        let sf = storefront(s)
        let n = link(s)?["picks_n"] as? Int ?? picksDefault
        let cid = comp["id"] as? String ?? ""
        let shelf = s.collection("music-shelf")
        let sc = scores(s)
        let lib = libraryHistory()
        let played = lib.played + shelf.map { ($0["artist"] as? String ?? "", 1) }
        var seeds = seedArtists(played: played, scores: sc)
        if seeds.isEmpty {                     // 资料库是空的、也没投过票：从你们最近聊的猜几位
            let recent = LocalTarot.recentLines(s, companion: cid, zh: true, userName: "TA")
            guard !recent.isEmpty else { return false }
            seeds = Array(parseArtistList(await ask(provider, key, system: "", recent + "\n\n按这些聊天猜 6 位 TA 可能喜欢的歌手或乐队。只输出一个 JSON 数组，元素是歌手在 Apple Music 上的名字（用原文），不要解释：\n[\"歌手1\", \"歌手2\"]")).prefix(6))
        }
        guard !seeds.isEmpty else { return false }
        let known = Set(played.flatMap { splitArtists($0.0).map { $0.lowercased() } } + seeds.map { $0.lowercased() })
        let blocked = sc.filter { $0.value <= blockScore }.map(\.key)
        let similar = "下面是一个人最近常听的歌手：\n" + seeds.joined(separator: "、") + "\n\n请推荐 10 位风格相近、但**不在上面名单里**的歌手或乐队，最好有一半是 TA 大概没听过的小众一点的。"
            + (blocked.isEmpty ? "" : "\n不要推荐这些：" + blocked.joined(separator: "、"))
            + "\n只输出一个 JSON 数组，元素是歌手在 Apple Music 上的名字（用原文，不要翻译），不要解释：\n[\"歌手1\", \"歌手2\"]"
        let fresh = parseArtistList(await ask(provider, key, system: "", similar)).filter { !known.contains($0.lowercased()) }
        var cands: [(Song, String)] = []
        for a in seeds.prefix(4) { cands += await topSongs(of: a, sf: sf, limit: 10).map { ($0, "familiar") } }
        for a in fresh.prefix(10) { cands += await topSongs(of: a, sf: sf, limit: 6).map { ($0, "new") } }
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? .distantPast
        let recentIDs = Set(s.collection("music-picks").filter { LocalStore.date(($0["day"] as? String).map { $0 + "T00:00:00.000Z" }) > cutoff }
            .compactMap { $0["song_id"] as? String })
        let heard = lib.heard.union(shelf.map { songKey($0["name"] as? String ?? "", $0["artist"] as? String ?? "") })
        var pool = buildPool(cands, heard: heard, recentIDs: recentIDs, scores: sc)
        guard pool.count >= n else { return false }
        let alt = await altNames(pool.map(\.0.id), sf: sf, zh: zh)
        for i in pool.indices { if let a = alt[pool[i].0.id] { pool[i].0.name = a.name; pool[i].0.artist = a.artist } }

        // 它来挑：只能从池子里挑，每首一句为什么，再跟 TA 说一两句
        let contact = LocalBrain.contact(comp, provider: provider)
        let fb = s.collection("music-picks").filter { !($0["vote"] as? String ?? "").isEmpty && ($0["day"] as? String ?? "") < day }.suffix(9)
        let voteWord = ["up": "多来点", "meh": "无感", "down": "少来点"]
        var lines = ["今天的私选候选备好了（程序从曲库里找的真歌，只能从这里挑；熟 = TA 常听的歌手，新 = 风格相近、TA 可能没听过的）："]
        lines += pool.map { "#\($0.0.id) \($0.0.name) - \($0.0.artist)（\($0.1 == "familiar" ? "熟" : "新")）" }
        if !fb.isEmpty {
            lines.append("TA 前几天对你挑的歌怎么说：")
            lines += fb.map { "- \($0["name"] ?? "") - \($0["artist"] ?? "")：\(voteWord[$0["vote"] as? String ?? ""] ?? "")" + (($0["reason"] as? String).map { $0.isEmpty ? "" : "「\($0)」" } ?? "") }
        }
        lines.append("挑 \(n) 首 TA 今天可能喜欢的，每首写一句为什么（\(whyMax) 字以内），再写一两句今天推歌时想跟 TA 说的话。只输出 JSON，不要别的："
                     + #"{"picks":[{"id":"编号","why":"为什么是这首"}],"say":"想跟 TA 说的话"}"#)
        let system = zh ? "你是\(contact.name)。\n\n\(contact.persona)" : "You are \(contact.name).\n\n\(contact.persona)"
        let byID = Dictionary(pool.map { ($0.0.id, $0.0) }, uniquingKeysWith: { a, _ in a })
        var chosen: [(Song, String)] = [], say = ""
        var prompt = lines.joined(separator: "\n")
        for _ in 0..<2 {
            let raw = await ask(provider, key, system: system, prompt, maxTokens: 1200)
            guard let a = raw.firstIndex(of: "{"), let z = raw.lastIndex(of: "}"), a < z,
                  let j = try? JSONSerialization.jsonObject(with: Data(raw[a...z].utf8)) as? [String: Any],
                  let ps = j["picks"] as? [[String: Any]] else { prompt += "\n\n上一次没按格式交，只输出那段 JSON。"; continue }
            var errs: [String] = [], seen = Set<String>(), ok: [(Song, String)] = []
            for (i, p) in ps.enumerated() {
                let id = "\(p["id"] ?? "")".trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                let why = (p["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let x = byID[id], !seen.contains(id), !why.isEmpty { seen.insert(id); ok.append((x, String(why.prefix(whyMax)))) }
                else { errs.append("第 \(i + 1) 首「\(id)」不在池子里、重复了或没写为什么") }
            }
            if ok.count == n && errs.isEmpty { chosen = ok; say = (j["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines); break }
            prompt += "\n\n上一次没收：要正好 \(n) 首，" + errs.joined(separator: "；") + "。改好整批再交。"
        }
        guard chosen.count == n else { return false }

        var rows = s.collection("music-picks").filter { ($0["day"] as? String) != day }
        var cards: [[String: Any]] = []
        for (pos, (x, why)) in chosen.enumerated() {
            rows.append(["day": day, "pos": pos, "song_id": x.id, "name": x.name, "artist": x.artist, "artwork": x.artwork,
                         "preview": x.preview, "url": x.url, "why": why, "vote": "", "stars": 0, "reason": ""])
            shelve(s, x, source: "pick", why: why)
            cards.append(["kind": "song", "text": why, "data": x.dict.merging(["why": why, "pick_day": day, "pos": pos]) { a, _ in a }])
        }
        s.saveCollection("music-picks", rows)
        // 发进它最近那个窗口（跟服务器一样：歌卡跟着它这条消息）
        if let conv = s.conversations.filter({ ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) })
            .max(by: { LocalStore.date($0["last_at"]) < LocalStore.date($1["last_at"]) })?["id"] as? String {
            s.addMessage(conv, role: "assistant", text: say.isEmpty ? (zh ? "今天给你挑了几首。" : "Picked a few for you today.") : say, cards: cards)
        }
        return true
    }

    // MARK: - 它那边的工具：share（发一首歌）/ now（TA 在听什么）

    static func toolSpec(zh: Bool) -> ToolSpec {
        ToolSpec(name: "music",
                 description: zh ? "用途：音乐。share=给 TA 发一首歌（曲库里找到才发得出歌卡，带试听，进 TA 的歌单）：query 写歌名、最好带歌手，why 写一句为什么想给 TA 听；now=看 TA 这会儿在听什么。"
                                 : "Music. share = send them a song (a card with a preview, only if the catalog has it; it goes on their shelf): query = song title, ideally with the artist; why = one line on why. now = what they're listening to right now.",
                 parametersJSON: #"{"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["share","now"]},"query":{"type":"string","description":"share：歌名，最好带上歌手"},"why":{"type":"string","description":"share：为什么想给 TA 听，一句"}}}"#)
    }

    static func runTool(_ a: [String: Any], host: LocalHost, zh: Bool) async -> LocalTools.Outcome {
        let s = host.store
        switch a["action"] as? String ?? "" {
        case "now":
            let line = nowLine(s, zh: zh)
            return .init(result: line.isEmpty ? (zh ? "这会儿没看到 TA 在放歌。想知道就问 TA。" : "Not seeing anything playing. Ask them if you want to know.") : line, card: nil)
        case "share":
            let q = (a["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return .init(result: "query 写歌名，最好带上歌手。", card: nil) }
            let sf = storefront(s)
            let found = await searchSongs(q, sf: sf)
            let alt = await altNames(found.map(\.id), sf: sf, zh: zh)
            let ql = q.lowercased()
            // 沾边才算：歌名（去括号）写在查询里，或查询里的字大半都在「歌名 + 歌手」里；翻唱 / 伴奏往后放
            func hits(_ x: Song) -> Bool {
                [x, alt[x.id]].compactMap { $0 }.contains { y in
                    let title = baseTitle(y.name)
                    let hay = "\(y.name) \(y.artist)".lowercased()
                    let chars = Set(ql.filter { !$0.isWhitespace })
                    return (!title.isEmpty && ql.contains(title)) || (!chars.isEmpty && Double(chars.filter { hay.contains($0) }.count) / Double(chars.count) >= 0.6)
                }
            }
            let matching = found.enumerated().filter { hits($0.element) }
                .sorted { ((isCoverish($0.element.name) ? 1 : 0), $0.offset) < ((isCoverish($1.element.name) ? 1 : 0), $1.offset) }
                .map(\.element)
            guard var best = matching.first else { return .init(result: "曲库里没找到「\(q)」。换一首，或者写上是谁唱的。", card: nil) }
            let leads = Set(matching.filter { baseTitle($0.name) == baseTitle(best.name) && !isCoverish($0.name) }.compactMap { splitArtists($0.artist).first?.lowercased() })
            if leads.count >= 2, !leads.contains(where: { ql.contains($0) }) {
                let opts = matching.prefix(4).map { "《\((alt[$0.id] ?? $0).name)》- \((alt[$0.id] ?? $0).artist)" }.joined(separator: "；")
                return .init(result: "叫这个名字的不止一首：\(opts)。想好是谁唱的，写上歌手再发一次。", card: nil)
            }
            if let a = alt[best.id] { best.name = a.name; best.artist = a.artist }
            let why = String((a["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            shelve(s, best, source: "share", why: why)
            var data = best.dict.merging(["why": why]) { a, _ in a }
            if let now = s.read("music-now.json") as? [String: Any], now["playing"] as? Bool ?? false,
               Date().timeIntervalSince(LocalStore.date(now["at"])) <= listenFresh { data["queue"] = true }
            let text = why.isEmpty ? "🎵 《\(best.name)》 — \(best.artist)" : why
            return .init(result: "发了：《\(best.name)》- \(best.artist)（进了 TA 的歌单）" + ((data["queue"] as? Bool ?? false) ? "，TA 正在一起听，会排进播放队列。" : "。"),
                         card: ["kind": "song", "text": text, "data": data])
        default:
            return .init(result: "action 写 share 或 now。", card: nil)
        }
    }
}
#endif
