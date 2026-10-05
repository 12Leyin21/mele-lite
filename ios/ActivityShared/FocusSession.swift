import Foundation

// MARK: - 这次专注（主 app、三个专注插件、小组件、灵动岛共用；只靠 Foundation）

struct FocusSession: Codable, Equatable {
    var id: String
    var start: Date
    var end: Date
    var label: String
    var companionName: String
    var lines: [String]
    var lockNow: Bool           // TA 开始时就开了「锁住这些 app」
    var lockAfter: Int          // 它定的：刷到第几条还不停就锁（0 = 不锁）
    var peekLine = ""           // 挡板上点「我就看一下」时它马上说的那句（开始时照聊天记录写好）
    var reached = 0             // 到过第几条
    var lastLine: String?

    /// 累计用到这么多分钟各弹一条（第 1..5 条）
    static let thresholds = [1, 3, 6, 10, 15]
    private static let key = "focus.state"

    static func load() -> FocusSession? {
        guard let d = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FocusSession.self, from: d)
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: Self.key) }
    }

    static func clear() { AppGroup.defaults.removeObject(forKey: key) }

    /// 分心多少分钟（到过的最高阈值）
    var distractedMinutes: Int { reached > 0 ? Self.thresholds[min(reached, Self.thresholds.count) - 1] : 0 }
    var shouldLock: Bool { lockNow || (lockAfter > 0 && reached >= lockAfter) }
}

/// 专注时插件替它弹过的话（提醒、「我就看一下」那句）：先记在 App Group 里，主 app 回前台报服务器进聊天流（09-29 Tilia）。
/// 跟「这次专注」分开放——专注结束清掉了、网络不通没报上去的，下次回前台照样报。
struct FocusSaid: Codable, Equatable {
    var focus: String
    var key: String             // t1..t5 / peek-<秒>；服务器按 (focus, key) 去重
    var at: Date
    var text: String
}

enum FocusOutbox {
    private static let key = "focus.said"

    static func load() -> [FocusSaid] {
        guard let d = AppGroup.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FocusSaid].self, from: d)) ?? []
    }

    static func add(_ s: FocusSaid) {
        var all = load().filter { !($0.focus == s.focus && $0.key == s.key) }
        all.append(s)
        save(Array(all.suffix(50)))
    }

    static func remove(_ done: [FocusSaid]) {
        save(load().filter { s in !done.contains { $0.focus == s.focus && $0.key == s.key } })
    }

    private static func save(_ all: [FocusSaid]) {
        if let d = try? JSONEncoder().encode(all) { AppGroup.defaults.set(d, forKey: key) }
    }
}
