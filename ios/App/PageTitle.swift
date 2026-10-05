import SwiftUI

/// 页面大标题左边一道竖杠：主题色、往下淡出（10-04 Tilia：底下的菜单换成四个点之后，靠标题认出在哪一页）
struct TitleBar: ViewModifier {
    @EnvironmentObject private var theme: AppTheme
    func body(content: Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(LinearGradient(colors: [theme.accent.opacity(0.75), theme.accent.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 5, height: 34)
            content
        }
    }
}

extension View {
    func titleBar() -> some View { modifier(TitleBar()) }
}
