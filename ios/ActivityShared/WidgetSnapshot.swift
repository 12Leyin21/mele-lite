import Foundation
import UIKit

/// 小组件看的那份快照（09-29）：主 app 每次刷新时写进 App Group，小组件只读它、自己不联网。
struct WidgetSnapshot: Codable, Equatable {
    var companionName: String = ""
    var wakesSaid: Int = 0              // 今天来找过你几次
    var lastWakeText: String?
    var lastWakeAt: Double?             // Unix 秒
    var drawerCount: Int = 0
    var drawerReady: Int = 0            // 能拆了的
    var updatedAt: Double = 0

    /// 比较有没有变时不看写的时间
    var withoutTime: WidgetSnapshot { var s = self; s.updatedAt = 0; return s }

    private static let key = "widget.snapshot"

    static func load() -> WidgetSnapshot {
        guard let d = AppGroup.defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: d) else { return WidgetSnapshot() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: Self.key) }
    }
}

