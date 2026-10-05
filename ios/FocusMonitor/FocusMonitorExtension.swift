import DeviceActivity
import Foundation
import UserNotifications
import WidgetKit

/// 盯着分心 app 的插件（离线跑）：累计用到 1/3/6/10/15 分钟各弹一条它写的提醒；该锁了就加挡板；时段结束撤挡板。
final class FocusMonitorExtension: DeviceActivityMonitor {
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard var st = FocusSession.load(), let i = FocusShared.index(of: event) else { return }
        st.reached = max(st.reached, i)
        let line = st.lines.indices.contains(i - 1) ? st.lines[i - 1] : (st.lines.last ?? "")
        st.lastLine = line
        st.save()
        if !line.isEmpty {
            let c = UNMutableNotificationContent()
            c.title = st.companionName
            c.body = line
            c.sound = .default
            c.userInfo = ["room": "focus"]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "focus-\(st.id)-\(i)", content: c, trigger: nil))
            FocusOutbox.add(FocusSaid(focus: st.id, key: "t\(i)", at: Date(), text: line))   // 回到 app 时进聊天
        }
        if st.shouldLock { Shield.apply() }       // 「我就看一下」解开以后，下一条到了再锁回去
        WidgetCenter.shared.reloadAllTimelines()  // 专注小组件上的分心分钟数
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        Shield.clear()
    }
}
