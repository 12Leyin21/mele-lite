import SwiftUI

/// 联系人的头像：服务器上有图就用图（AppModel 按版本号缓存），没有就是首字母渐变圆。
struct CompanionAvatar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let companion: CompanionDTO
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let img = model.avatarImages[companion.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        Text(String(companion.name.prefix(1)))
                            .font(Typo.icon(size * 0.42, .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: size > 40 ? 1.5 : 1.2))
    }
}
