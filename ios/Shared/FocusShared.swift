import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

// MARK: - 哨兵：主 app 和三个插件共用（09-29）
//
// 「这次专注」存在 App Group 里：主 app 开始时写，插件（离线跑）读它弹提醒、加挡板，主 app 结束时读它报服务器。
// FocusSession / FocusOutbox 搬到了 ActivityShared/FocusSession.swift（小组件和灵动岛也要读，那边不带屏幕使用时间框架）。

enum FocusShared {
    static var defaults: UserDefaults { AppGroup.defaults }
    static var thresholds: [Int] { FocusSession.thresholds }
    static let activity = DeviceActivityName("focus")
    static let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("focus"))

    static func eventName(_ i: Int) -> DeviceActivityEvent.Name { .init("t\(i)") }
    static func index(of event: DeviceActivityEvent.Name) -> Int? { Int(event.rawValue.dropFirst()) }
}

/// TA 挑的分心 app（苹果只给看不懂的代号，不出手机）
enum FocusSelection {
    private static let key = "focus.selection"

    static func load() -> FamilyActivitySelection {
        guard let d = FocusShared.defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(FamilyActivitySelection.self, from: d) else { return FamilyActivitySelection() }
        return s
    }

    static func save(_ s: FamilyActivitySelection) {
        if let d = try? JSONEncoder().encode(s) { FocusShared.defaults.set(d, forKey: key) }
    }

    static func count(_ s: FamilyActivitySelection) -> Int {
        s.applicationTokens.count + s.categoryTokens.count + s.webDomainTokens.count
    }
}

/// 挡板：只挡 TA 挑的那些
enum Shield {
    static func apply() {
        let s = FocusSelection.load()
        let store = FocusShared.store
        store.shield.applications = s.applicationTokens.isEmpty ? nil : s.applicationTokens
        store.shield.applicationCategories = s.categoryTokens.isEmpty ? nil : .specific(s.categoryTokens)
        store.shield.webDomains = s.webDomainTokens.isEmpty ? nil : s.webDomainTokens
    }

    static func clear() { FocusShared.store.clearAllSettings() }
}
