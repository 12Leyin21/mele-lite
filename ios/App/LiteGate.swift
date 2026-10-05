import SwiftUI

/// Mele Lite（手机里的小管家，没有服务器）跟 Mele 共用这份代码。
/// 要一直醒着的服务器才能做的功能，在 Lite 里照样摆出来，灰着、点不了，写「连上 Mele Host 才能用」（Tilia 10-04）。
enum Lite {
    /// 这是 Lite 这个 App（编译时定）
    static var on: Bool {
        #if LITE
        true
        #else
        false
        #endif
    }
    /// Lite 而且没连 Mele Host：数据在手机里的小管家那（10-04）
    static var local: Bool { on && !HostLink.connected }
    /// Lite 连着自己的 Mele Host：跟正式版一样直接跟服务器说话
    static var hosted: Bool { on && HostLink.connected }
}

private struct NeedsHost: ViewModifier {
    @EnvironmentObject private var theme: AppTheme
    let note: Bool

    func body(content: Content) -> some View {
        if Lite.local {
            content
                .disabled(true)
                .opacity(0.42)
                .overlay(alignment: .topTrailing) {
                    if note {
                        Label("连上 Mele Host 才能用", systemImage: "lock.fill")
                            .font(Typo.sans(Typo.Size.caption, .medium))
                            .foregroundStyle(theme.inkDim)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.85)))
                            .padding(8)
                    }
                }
        } else {
            content
        }
    }
}

extension Notification.Name {
    /// Lite：它通过了小号的好友申请（消息列表刷新一下）
    static let liteFriendAccepted = Notification.Name("liteFriendAccepted")
}

extension View {
    /// Lite 里灰掉（note = 右上角挂一个「连上 Mele Host 才能用」）；Mele 里原样
    func needsHost(note: Bool = true) -> some View { modifier(NeedsHost(note: note)) }

    /// Lite 里整个不显示（那种灰着也没意义的小按钮）
    @ViewBuilder func hiddenInLite() -> some View {
        if Lite.local { EmptyView() } else { self }
    }
}
