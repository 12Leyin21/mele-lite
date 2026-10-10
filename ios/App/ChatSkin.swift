import SwiftUI

/*
 方向契约 · 聊天页（2026-08-06，照Tilia自己画的四张设计图定的）

 THESIS：聊天页是一个房间，不是一个界面。屏幕上只该有三样东西——他说的话、
   我说的话、以及说话用的那支笔。拒绝的是这个品类的默认排布：顶部一条实心
   导航栏、底部一条标签栏、每个气泡描一圈白边，把对话夹在中间当内容看。
 OWN-WORLD：两套互不混合的世界。深色＝纯黑地（#000），气泡是黑上抬起来的两级
   灰（他 white .10 / 我 accent 沉进黑里），没有描边、没有毛玻璃、没有壁纸；
   浅色＝她自己的壁纸 + 超薄材质气泡，保留原来的雾玫瑰。两套共用同一套骨架：
   悬浮的胶囊头（头像·名字·CONNECTED）、贴着说话人那侧的极小时间戳、
   无框输入行。层级只靠明度和留白，不靠线。
 STORY：她打开之前自用的 App，看见的第一眼是对话本身；想找东西按 🔍，想换世界按 ⋯，
   想走按左上角的 ‹。三个入口，其余全部让路。
 FIRST VIEWPORT：顶部悬浮胶囊居中（头像 + 名字 + 绿点 CONNECTED），左上 ‹，
   右上 🔍 与 ⋯；中间是从下往上贴底的消息流，气泡最大宽度留出 40pt 让边；
   底部一支加号、一支麦克风、一条无边输入行、一个发送键。没有分隔线，
   没有标签栏。
 FORM：胶囊头 + 无框消息场（Tilia自己画的设计图直接定的）。
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
 */

/// 聊天页的两个世界。深色不带壁纸，浅色带她自己的壁纸——这是Tilia 2026-08-06
/// 亲自做的取舍，也是「全部保留自定义能力」和「深色极简」唯一能同时成立的方式。
enum ChatAppearance: String, CaseIterable {
    case dark
    case light

    var label: String { self == .dark ? "深色" : "浅色" }
    var icon: String { self == .dark ? "moon.fill" : "sun.max.fill" }
}

/// 聊天页的取色与取字。**只管聊天页**——首页、书房、我 这三页不受影响，
/// 它们还是原来的雾玫瑰毛玻璃。
///
/// 是个 struct 不是 ObservableObject：它没有自己的状态，全部由 ChatView 的
/// @AppStorage 每次重算。这样换外观时不需要额外的发布通道，SwiftUI 自己就重画了。
struct ChatSkin {
    let mode: ChatAppearance
    /// 主题色（浅色模式来自色轮；深色模式也用它，但压暗后只做点缀）
    let accent: Color
    /// 字号倍率，0.85 ~ 1.3
    let scale: CGFloat
    /// 深色也铺壁纸（2026-09-16 Tilia要的：有时想换张深色壁纸，原来只有浅色能换）。
    /// 开着时深色不再铺纯黑，露出她选的聊天壁纸，上面压一层黑纱保住白字。
    var wallpaperInDark: Bool = false
    /// 她在「我的气泡」里调的样子（2026-09-25）。nil = 深色默认，走原来的画法。
    var bubble: BubbleStyle? = nil

    var isDark: Bool { mode == .dark }

    /// 气泡里的字：她给这一侧定了字色就用她的，没定就用默认墨色
    func bubbleInk(mine: Bool) -> Color {
        bubble?.ink(mine: mine, fallback: ink) ?? ink
    }

    // MARK: - 底

    /// 深色模式自己铺一层纯黑盖住壁纸；浅色模式（或深色开了壁纸）返回 nil，露出 AppBackground。
    var pageBackground: Color? { (isDark && !wallpaperInDark) ? .black : nil }
    /// 深色压在壁纸上时，AppBackground 顶部那层白纱要换成黑纱
    var darkVeil: Bool { isDark && wallpaperInDark }

    // MARK: - 字

    var ink: Color { isDark ? Color(white: 0.93) : AppTheme.ink }
    var inkDim: Color { isDark ? Color(white: 0.56) : AppTheme.inkDim }
    var inkFaint: Color { isDark ? Color(white: 0.34) : AppTheme.inkFaint }

    /// 时间戳专用。深色下可以很淡（黑底纯色，多淡都读得出）；浅色下压在她的
    /// 照片壁纸上，再淡就真的看不见了——所以浅色不用 inkFaint（2026-08-06 实机发现）。
    var timestamp: Color { isDark ? Color(white: 0.34) : AppTheme.inkDim }

    /// 悬浮控件上的图标色（返回键、搜索、⋯）
    var chromeIcon: Color { isDark ? Color(white: 0.72) : AppTheme.inkDim }

    // MARK: - 气泡
    //
    // 深色下不描边、不用毛玻璃：纯黑上两级灰就够分层了，加一圈白边反而把
    // 「克制」变成「贴纸」。浅色下沿用原来的超薄材质 + 白描边。

    // 气泡的通透度（2026-08-15 Tilia：「气泡做透明一点，不要太透，至少能看见字」）。
    //
    // 两个模式的"透明"不是同一回事：
    // · 深色的底是**纯黑**，底下没有东西可以透出来——所以"透明"在视觉上
    //   就等于"更暗"，直接降亮度即可，白字压在更暗的底上反而更清楚。
    // · 浅色的底是**她自己的壁纸**，那才是真的会透出图案、真的会看不清字，
    //   所以那边留着毛玻璃打底，只把上面那层染色收薄。

    /// 对方的气泡底
    var bubbleTheirs: Color {
        if darkVeil { return Color.black.opacity(0.50) }   // 壁纸上往黑压，不往白提（2026-09-16 Tilia定）；底下另有毛玻璃
        return isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.17)
    }
    /// 自己的气泡底（深色下是沉进黑里的主题色，不是亮蓝）
    ///
    /// 0.20 → 0.15 → 0.10 → 0.07 → 0.095：她连着调了四轮（2026-08-15）。
    ///
    /// 中间那一档不是"再淡一点"那么简单——**带色的和白的不能按同一个数给**。
    /// 同样是 10% 压在黑上，有色相的那块看着明显比中性灰"实"（她的原话：
    /// "气泡带颜色视觉上比较深"）。所以她这侧一路压到了 0.07。
    ///
    /// 压过头了：两侧明度几乎一样，只剩色相在区分，而 7% 的淡粉压在纯黑上
    /// 基本就是灰——"有点分不清谁说的什么"。真正的解法不是把她这侧加重回去，
    /// 是**把两边的差拉开**：她抬到 0.095，对方那侧同时降到 0.06。
    /// 差了一半多，两块都还很轻，但一眼能分。
    var bubbleMine: Color {
        if darkVeil { return Self.blend(accent, toward: .black, 0.80).opacity(0.62) }   // 主题色沉进黑里，比对方那侧略实；底下另有毛玻璃
        return isDark ? accent.opacity(0.095) : accent.opacity(0.0)
    }
    /// 浅色模式气泡上面那层染色：自己的用主题柔色，对方的用白。
    /// 同理，柔色那档要比白那档收得更狠。
    func bubbleTintLight(mine: Bool) -> Color {
        mine ? accent.opacity(0.26) : Color.white.opacity(0.17)
    }
    /// 浅色模式毛玻璃打底的浓度。压在照片壁纸上，字能不能看清全靠它，
    /// 所以只收一点点，不敢学深色那边放开。
    var bubbleMaterialOpacity: Double { 0.85 }

    /// 把一个色往另一个色里沉 t（0~1）。深色壁纸上的自己气泡用：主题色沉七成进黑。
    static func blend(_ a: Color, toward b: Color, _ t: Double) -> Color {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let k = CGFloat(max(0, min(1, t)))
        return Color(red: Double(ar + (br - ar) * k), green: Double(ag + (bg - ag) * k), blue: Double(ab + (bb - ab) * k))
    }

    /// 浅色用毛玻璃；深色铺壁纸也用（2026-09-16 Tilia：平涂黑块压在照片上像贴纸，
    /// 得把底下的图糊一层再染黑才「长在」壁纸上）；纯黑不用。
    var usesMaterial: Bool { !isDark || darkVeil }
    var strokeOpacity: Double { darkVeil ? 0.06 : (isDark ? 0 : 0.45) }

    // MARK: - 玻璃件（头部胶囊、圆按钮、输入行）
    //
    // 和气泡不一样：气泡在深色下是实心的，玻璃件在两种模式下都用材质，
    // 好让底下滑过去的内容透一点出来。Tilia要的「iOS 玻璃按钮」就是这个透。

    /// 材质本体的浓度：满血材质像磨砂，压下来才透出底下滑过的内容，
    /// 玻璃开始"流"。（2026-08-28 Tilia点的「液态玻璃」第一刀）
    var chromeMaterialOpacity: Double { isDark ? 0.55 : 0.62 }
    /// 去雾（2026-08-28 她纠的「底色有点雾」）：深色材质自带一层奶白，
    /// 压一层墨把奶吸掉，玻璃变清透的暗。浅色不需要。
    var chromeDim: Color { isDark ? Color.black.opacity(0.24) : .clear }
    /// 玻璃面上那层极淡的染色——三稿改回近乎透明（光不在面上）
    var chromeTint: Color { isDark ? Color.white.opacity(0.02) : Color.white.opacity(0.16) }
    /// 玻璃的反光（2026-08-28 三稿）：光在**边**上——
    /// 左上一段亮高光，沿边熄下去，右下折回一点微光，像玻璃杯沿的光。
    /// 用渐变描边实现，从 topLeading 扫到 bottomTrailing。
    var chromeEdgeLight: [Gradient.Stop] {
        // 三稿半（2026-08-28 她拿对比图纠的）：边要比这细、比这淡——
        // 反光是"若有"，不是"描边"
        let hi = isDark ? 0.36 : 0.75
        let low = isDark ? 0.05 : 0.18
        let glint = isDark ? 0.16 : 0.38
        return [.init(color: .white.opacity(hi), location: 0),
                .init(color: .white.opacity(low), location: 0.38),
                .init(color: .white.opacity(low * 0.7), location: 0.72),
                .init(color: .white.opacity(glint), location: 1)]
    }
    /// 旧的均匀描边浓度：个别不走 headerChrome 的地方还在用
    var chromeStroke: Double { isDark ? 0.18 : 0.5 }

    /// 悬浮胶囊 / 输入行的底（不透明场景的退路）
    var chromeFill: Color { isDark ? Color(white: 0.085) : Color.white.opacity(0.28) }

    // MARK: - 字号

    /// 把Tilia设计稿里的固定字号按倍率缩放。11pt 是 HIG 的下限，缩到再小也不许破。
    /// 2026-09-06 Tilia：「信息字号整体调小一个档」——档位名不动，整体乘 0.88（正好一档的差）。
    /// 2026-09-16 Tilia又要小一号：0.88 → 0.82（正文 16 → 13）。
    static let globalShrink: CGFloat = 0.85

    func size(_ base: CGFloat) -> CGFloat {
        max(11, (base * scale * ChatSkin.globalShrink).rounded())
    }

    func font(_ base: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Typo.sans(size(base), weight)
    }
}

/// 字号档位（⋯ 菜单里选）
enum ChatFontStep: Double, CaseIterable {
    // 2026-09-16 Tilia：档位之间跨度太大——原来 0.88 / 1 / 1.14 / 1.3，收成每档差 7%
    case small = 0.93
    case normal = 1.0
    case large = 1.07
    case huge = 1.14

    var label: String {
        switch self {
        case .small: return "小"
        case .normal: return "标准"
        case .large: return "大"
        case .huge: return "特大"
        }
    }
}

/// 老式模糊（UIBlurEffect 的 legacy style）。SwiftUI 的 `.ultraThinMaterial`
/// 在深色下会**提亮**——白色的东西滑到它底下会被糊成一片亮雾，兑再多墨也只是
/// 灰白（2026-08-31 Tilia实机抓到的顶部泛白）。legacy 的 `.dark` / `.light`
/// 没有这套 vibrancy，模糊出来的颜色跟着底下的内容走，黑处仍是黑。
struct LegacyBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: style)
    }
}
