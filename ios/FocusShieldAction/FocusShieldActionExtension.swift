import ManagedSettings
import UserNotifications

/// 挡板上的按钮：「回去」关掉那个 app；「我就看一下」撤挡板（下一条提醒到了再锁回去，这段照样算分心）。
final class FocusShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) { respond(action, completionHandler) }
    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) { respond(action, completionHandler) }
    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) { respond(action, completionHandler) }

    private func respond(_ action: ShieldAction, _ done: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed: done(.close)
        case .secondaryButtonPressed:
            // 它马上说一句（Tilia 09-29：不拦，但让 TA 想一下；开始专注时照聊天记录写好的），然后放行
            if let s = FocusSession.load(), !s.peekLine.isEmpty {
                let c = UNMutableNotificationContent()
                c.title = s.companionName
                c.body = s.peekLine
                c.sound = .default
                c.userInfo = ["room": "focus"]
                let now = Date()
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "focus-peek-\(s.id)-\(now.timeIntervalSince1970)",
                                                                             content: c, trigger: nil))
                FocusOutbox.add(FocusSaid(focus: s.id, key: "peek-\(Int(now.timeIntervalSince1970))", at: now, text: s.peekLine))
            }
            Shield.clear()
            done(.defer)
        @unknown default: done(.close)
        }
    }
}
