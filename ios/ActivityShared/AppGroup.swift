import Foundation

/// 主 app 和所有插件共用的那块地方（App Group）。ID 在 project.yml 的 entitlements 里也写了——几处必须一模一样，
/// 不一样的话小组件读到的永远是空的。
enum AppGroup {
    static let id = "group.chat.mele.app"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var dir: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
    }
}
