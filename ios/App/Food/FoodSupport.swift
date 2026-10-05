import SwiftUI

// 饮食页从宿主 app 要的东西（fed-myself 的 FoodLogSupport 换成 Mele 的，09-29）。
// 主题（AppTheme 的 ink / accent）、AppBackground、AuthImageView、Radii、CameraPicker 用 Mele 自己的，这里只补缺的。

enum FoodLogConfig {
    /// 界面上怎么叫 TA（「Lumi 在估…」「Lumi 记的」）：主联系人的名字，开饮食页时写进来
    static var aiName: String {
        let n = (UserDefaults.standard.string(forKey: "foodAIName") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "TA" : n
    }
    /// 网络走 Mele 的 APIClient（登录凭证、服务器地址都在它身上）
    nonisolated(unsafe) static var api: APIClient?
}

/// fed-myself 的字体：Mele 里一律从 Typo 取
enum Fonts {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { Typo.sans(size, weight) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { Typo.accent(size, weight) }
    static func serifItalic(_ size: CGFloat) -> Font { Typo.accent(size).italic() }
}

/// Library 的「饮食」格子开的就是它
struct FoodRoom: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FoodDiaryView()
            .onAppear { UserDefaults.standard.set(model.primaryCompanion?.name ?? "", forKey: "foodAIName") }
    }
}


extension View {
    /// fed-myself 用的是 iOS 26 的 glassEffect；Mele 还支持 iOS 18，那边退成磨砂
    @ViewBuilder func foodGlass<S: Shape>(interactive: Bool = false, clear: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(clear ? .clear : (interactive ? .regular.interactive() : .regular), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
