import SwiftUI
import UIKit

/*
 我的气泡（2026-09-25 Tilia要的）

 以前气泡的样子写死在 ChatSkin 里，每改一次都要找克克。现在深色、浅色各存一套
 BubbleStyle（AppStorage 里一段 JSON），聊天页照着画；左下角加号 →「我的气泡」改。

 「默认」= 存的那段是空串：
 · 深色的默认就是原来那套（纯黑上两级灰 / 深色铺壁纸那套），一个像素都不动，走 legacy 画法；
 · 浅色的默认换成 lightDefault——她嫌原来的浅色气泡太灰，这一页就是为这个来的。
 每个模式另有四个预设格，存她自己起名的样子。
 */

struct BubbleStyle: Codable, Equatable, Hashable {
    enum Material: String, Codable, CaseIterable {
        case solid, translucent, glass, gradient
        var label: String {
            switch self {
            case .solid: return "纯色"
            case .translucent: return "半透明"
            case .glass: return "玻璃"
            case .gradient: return "渐变"
            }
        }
    }

    /// 头像摆在哪
    enum Layout: String, Codable, CaseIterable {
        case side      // 头像挨着这一串第一个气泡，整串缩进对齐（她给的参考图二）
        case header    // 头像单独一行当这一串的抬头（2026-08-15 起的样子）
        case none      // 同上但不放头像
        var label: String {
            switch self {
            case .side: return "头像在旁边"
            case .header: return "头像在上面"
            case .none: return "不放头像"
            }
        }
        var icon: String {
            switch self {
            case .side: return "person.crop.circle.badge"
            case .header: return "person.crop.circle"
            case .none: return "circle.dashed"
            }
        }
    }

    var material: Material = .glass
    /// 主颜色，"RRGGBB"；nil = 他那边白、我这边跟主题色走
    var colorMu: String? = nil
    var colorMine: String? = nil
    /// 文字颜色；nil = 跟着深浅走的默认墨色
    var textMu: String? = nil
    var textMine: String? = nil
    /// 气泡透明度 0~0.95：越大越透（页面上显示的就是这个数）
    var transparency: Double = 0.6
    /// 玻璃：模糊浓度 0~1
    var blur: Double = 0.55
    /// 玻璃：亮度 -0.3~0.3（正数蒙白、负数蒙黑；页面上显示成 70%~130%）
    var brightness: Double = 0.06
    /// 玻璃：内侧一层柔和高光
    var highlight: Bool = true
    /// 玻璃：边框光 0~1（替掉参考图里的「背景饱和度」——iOS 不让 App 调毛玻璃的饱和度）
    var edgeLight: Double = 0.55
    var cornerRadius: Double = 18
    /// 尾巴 = 朝说话人那侧的下角收成小尖角
    var tail: Bool = true
    var layout: Layout = .header
    /// 气泡之间的间距（2026-09-25 加的；可选，老存档里没有这一项也能解开）
    var spacing: Double? = nil
    var rowSpacing: Double {
        get { spacing ?? 10 }
        set { spacing = newValue }
    }
    /// 气泡最长能伸到离对面屏幕边多远（pt）；nil = 原来的 20（头像在旁边）/ 26（其他）
    var reach: Double? = nil
    func farReach(side: Bool) -> Double { reach ?? (side ? 20 : 26) }
    /// 设置页「长度」滑块：往右 = 更长（= 离对面边更近）
    var lengthKnob: Double {
        get { 60 - (reach ?? 20) }
        set { reach = 60 - newValue }
    }

    /// 浅色的新默认：比原来那版少一层灰（原来是 ultraThin 0.85 + 白 0.17 / 主题色 0.26）
    static let lightDefault = BubbleStyle(
        material: .glass, colorMu: "FFFFFF", colorMine: nil, textMu: nil, textMine: nil,
        transparency: 0.55, blur: 0.45, brightness: 0.08, highlight: true, edgeLight: 0.6,
        cornerRadius: 18, tail: true, layout: .header)

    /// 深色默认走老画法；有人动了滑块才从这份起步
    static let darkSeed = BubbleStyle(
        material: .translucent, colorMu: "FFFFFF", colorMine: nil, textMu: nil, textMine: nil,
        transparency: 0.9, blur: 0.4, brightness: 0, highlight: false, edgeLight: 0.3,
        cornerRadius: 18, tail: true, layout: .header)

    static func seed(for mode: ChatAppearance) -> BubbleStyle {
        mode == .light ? lightDefault : darkSeed
    }

    // MARK: - 存取

    static func storageKey(_ mode: ChatAppearance) -> String {
        mode == .light ? "bubbleStyleLight" : "bubbleStyleDark"
    }
    static func presetsKey(_ mode: ChatAppearance) -> String {
        mode == .light ? "bubblePresetsLight" : "bubblePresetsDark"
    }

    /// 同一段 JSON 每次重画都要解一次，记住上一次的结果
    private static var decodeMemo: [String: BubbleStyle] = [:]

    static func decode(_ raw: String) -> BubbleStyle? {
        guard !raw.isEmpty else { return nil }
        if let hit = decodeMemo[raw] { return hit }
        guard let data = raw.data(using: .utf8),
              let style = try? JSONDecoder().decode(BubbleStyle.self, from: data) else { return nil }
        if decodeMemo.count > 32 { decodeMemo.removeAll() }
        decodeMemo[raw] = style
        return style
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 聊天页真正用的那份：存了就用存的；没存时浅色用新默认，深色返回 nil（走老画法）
    static func effective(raw: String, mode: ChatAppearance) -> BubbleStyle? {
        decode(raw) ?? (mode == .light ? lightDefault : nil)
    }

    // MARK: - 取色

    func fill(mine: Bool, accent: Color) -> Color {
        let hex = mine ? colorMine : colorMu
        return hex.flatMap(Color.init(hex:)) ?? (mine ? accent : .white)
    }

    func ink(mine: Bool, fallback: Color) -> Color {
        (mine ? textMine : textMu).flatMap(Color.init(hex:)) ?? fallback
    }
}

struct BubblePreset: Codable, Equatable {
    var name: String
    var style: BubbleStyle

    static func decodeList(_ raw: String) -> [BubblePreset?] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([BubblePreset?].self, from: data) else {
            return [nil, nil, nil, nil]
        }
        return Array((list + [nil, nil, nil, nil]).prefix(4))
    }

    static func encodeList(_ list: [BubblePreset?]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Color {
    init?(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

// MARK: - 画气泡

/// 聊天气泡的底（聊天页、设置页预览共用）。形状跟着圆角/尾巴走；
/// skin.bubble 为 nil 时一笔不差地走原来的深色画法。
struct ChatBubbleBackground: View {
    let skin: ChatSkin
    let mine: Bool
    /// 有几处（语气小药丸）是「我这侧的形状、他那侧的颜色」
    var tinted: Bool? = nil

    var body: some View {
        let style = skin.bubble
        let r = CGFloat(style?.cornerRadius ?? 18)
        let tailOn = style?.tail ?? true
        let small = tailOn ? min(4, r) : r
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: r,
                                              bottomLeading: mine ? r : small,
                                              bottomTrailing: mine ? small : r,
                                              topTrailing: r),
            style: .continuous)
        let colored = tinted ?? mine
        if let style {
            custom(style, shape: shape, colored: colored)
        } else {
            legacy(shape: shape, colored: colored)
        }
    }

    @ViewBuilder
    private func custom(_ style: BubbleStyle, shape: UnevenRoundedRectangle, colored: Bool) -> some View {
        let base = style.fill(mine: colored, accent: skin.accent)
        let alpha = max(0.05, 1 - style.transparency)
        ZStack {
            switch style.material {
            case .solid:
                shape.fill(base.opacity(alpha))
            case .translucent:
                shape.fill(base.opacity(alpha * 0.75))
            case .gradient:
                shape.fill(LinearGradient(
                    colors: [base.opacity(alpha),
                             ChatSkin.blend(base, toward: .white, 0.45).opacity(alpha * 0.8)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            case .glass:
                // 模糊浓度：前六成只加 ultraThin 的浓度，再往上叠一层 regular
                let b = style.blur
                shape.fill(.ultraThinMaterial).environment(\.colorScheme, .light)
                    .opacity(min(1, b / 0.6))
                if b > 0.6 {
                    shape.fill(.regularMaterial).environment(\.colorScheme, .light)
                        .opacity((b - 0.6) / 0.4 * 0.85)
                }
                shape.fill(base.opacity(alpha))
                if style.brightness > 0 {
                    shape.fill(Color.white.opacity(style.brightness))
                } else if style.brightness < 0 {
                    shape.fill(Color.black.opacity(-style.brightness))
                }
                if style.highlight {
                    shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.32), location: 0),
                                                      .init(color: .white.opacity(0), location: 0.55)],
                                              startPoint: .top, endPoint: .bottom))
                }
                if style.edgeLight > 0 {
                    let e = style.edgeLight
                    shape.strokeBorder(
                        LinearGradient(stops: [.init(color: .white.opacity(0.95 * e), location: 0),
                                               .init(color: .white.opacity(0.25 * e), location: 0.4),
                                               .init(color: .white.opacity(0.15 * e), location: 0.72),
                                               .init(color: .white.opacity(0.55 * e), location: 1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.9)
                }
            }
        }
    }

    /// 2026-09-25 之前的画法，原样搬过来（深色默认还用它）
    @ViewBuilder
    private func legacy(shape: UnevenRoundedRectangle, colored: Bool) -> some View {
        ZStack {
            if skin.darkVeil {
                shape.fill(.ultraThinMaterial).environment(\.colorScheme, .light).opacity(0.50)
                shape.fill(colored ? skin.bubbleMine : skin.bubbleTheirs)
                shape.stroke(Color.white.opacity(skin.strokeOpacity), lineWidth: 0.5)
            } else if skin.usesMaterial {
                shape.fill(.ultraThinMaterial).opacity(skin.bubbleMaterialOpacity)
                shape.fill(skin.bubbleTintLight(mine: colored))
                shape.stroke(Color.white.opacity(skin.strokeOpacity), lineWidth: 1)
            } else {
                shape.fill(colored ? skin.bubbleMine : skin.bubbleTheirs)
            }
        }
    }
}

// MARK: - 思考链的底板（2026-09-25 Tilia顺手要的）

/// 思考链那块底板的旋钮。单独存（不进气泡预设），这样深色只调思考链时气泡还能留在原来的画法上。
struct ThoughtStyle: Codable, Equatable, Hashable {
    /// 0~0.9：越大越透
    var transparency: Double = 0
    /// -0.3~0.3：正数蒙白、负数蒙黑
    var brightness: Double = 0
    /// 亮边 0~1（Lumi 09-28 Tilia：默认跟之前自用的 App一样没有亮边，想要的在「我的气泡」里调）。
    /// 可选：老存档里没有这一项也能解开
    var edge: Double? = nil
    var edgeLight: Double {
        get { edge ?? 0 }
        set { edge = newValue > 0.001 ? newValue : nil }
    }
    /// 思考链小字的颜色 "RRGGBB"（10-04 Tilia：深色模式配浅色底板时小字看不清）；nil = 跟着皮肤的淡墨色
    var ink: String? = nil

    func inkColor(fallback: Color) -> Color { ink.flatMap { Color(hex: $0) } ?? fallback }

    static func key(_ mode: ChatAppearance) -> String {
        mode == .light ? "thoughtStyleLight" : "thoughtStyleDark"
    }

    static func decode(_ raw: String) -> ThoughtStyle {
        guard let data = raw.data(using: .utf8),
              let style = try? JSONDecoder().decode(ThoughtStyle.self, from: data) else { return ThoughtStyle() }
        return style
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 思考链底板：照之前自用的 App聊天页展开思考链那块（半透明的雾，明确和实心气泡分开，只有一圈极淡的描边），
/// 再按她的旋钮调透明度、亮度、亮边
struct ThoughtPanelBackground: View {
    let skin: ChatSkin
    let style: ThoughtStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.control, style: .continuous)
        ZStack {
            if skin.darkVeil {
                // 深色铺壁纸：跟气泡同一套暗玻璃，比气泡再淡一点
                shape.fill(.ultraThinMaterial).environment(\.colorScheme, .light).opacity(0.45)
                shape.fill(Color.black.opacity(0.36))
                shape.stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            } else {
                shape.fill(.ultraThinMaterial).opacity(skin.isDark ? 0.45 : 0.55)
                shape.fill(skin.isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.10))
                shape.stroke(Color.white.opacity(skin.isDark ? 0.06 : 0.30), lineWidth: 0.5)
            }
        }
        .opacity(1 - style.transparency)
        .overlay {
            if style.brightness > 0 {
                shape.fill(Color.white.opacity(style.brightness))
            } else if style.brightness < 0 {
                shape.fill(Color.black.opacity(-style.brightness))
            }
        }
        .overlay {
            if style.edgeLight > 0 {
                shape.strokeBorder(
                    LinearGradient(stops: skin.chromeEdgeLight.map { .init(color: $0.color.opacity(style.edgeLight * 1.6), location: $0.location) },
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.75)
            }
        }
    }
}

// MARK: - 顶部淡出雾（2026-09-25 Tilia要能调）

/// 聊天页最上面那层渐进模糊（消息滑到状态栏底下被雾化）的旋钮。
/// 存空串 = 原来那套（深色 legacy .dark 模糊 + 上浓下淡的墨；浅色 ultraThin + 白 0.30）。
struct FadeStyle: Codable, Equatable, Hashable {
    /// 模糊 0~1（模糊那层的浓度）
    var blur: Double = 1
    /// 明度 -0.5~0.5：正数蒙白、负数蒙黑
    var brightness: Double = 0
    /// 染色，"RRGGBB"
    var color: String = "FFFFFF"
    /// 染色浓度 0~1
    var colorAmount: Double = 0.30
    /// 饱和度 0~2（1 = 不变）
    var saturation: Double = 1
    /// 雾有多高（pt）
    var height: Double = 96

    static func seed(for mode: ChatAppearance) -> FadeStyle {
        mode == .light ? FadeStyle()
                       : FadeStyle(blur: 1, brightness: 0, color: "000000", colorAmount: 0.6, saturation: 1, height: 96)
    }

    static func key(_ mode: ChatAppearance) -> String {
        mode == .light ? "fadeStyleLight" : "fadeStyleDark"
    }

    static func decode(_ raw: String) -> FadeStyle? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FadeStyle.self, from: data)
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 顶部淡出雾本体（聊天页和设置页预览共用）。style 为 nil 时一笔不差地画原来那套。
struct TopFadeOverlay: View {
    let isDark: Bool
    let style: FadeStyle?
    /// 预览里用：不按 style.height，给多高画多高
    var fixedHeight: CGFloat? = nil

    var body: some View {
        Group {
            if let style {
                ZStack {
                    if isDark {
                        LegacyBlur(style: .dark).opacity(style.blur)
                    } else {
                        Rectangle().fill(.ultraThinMaterial).opacity(style.blur)
                    }
                    Rectangle().fill((Color(hex: style.color) ?? .white).opacity(style.colorAmount))
                    if style.brightness > 0 {
                        Rectangle().fill(Color.white.opacity(style.brightness))
                    } else if style.brightness < 0 {
                        Rectangle().fill(Color.black.opacity(-style.brightness))
                    }
                }
                .saturation(style.saturation)
            } else if isDark {
                // 原来的深色：legacy .dark 模糊往暗里兑，墨上浓下淡（2026-08-31 两次「泛白」修出来的）
                ZStack {
                    LegacyBlur(style: .dark)
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.90), location: 0),
                        .init(color: .black.opacity(0.74), location: 0.30),
                        .init(color: .black.opacity(0.48), location: 0.60),
                        .init(color: .black.opacity(0.24), location: 0.85),
                        .init(color: .black.opacity(0.12), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            } else {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.white.opacity(0.30))
                }
            }
        }
        // 十档余弦曲线（2026-08-28 她抓的「还是有个断层」）：雾往下是化开的，不是断的
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.14),
            .init(color: .black.opacity(0.96), location: 0.26),
            .init(color: .black.opacity(0.88), location: 0.38),
            .init(color: .black.opacity(0.74), location: 0.50),
            .init(color: .black.opacity(0.56), location: 0.62),
            .init(color: .black.opacity(0.38), location: 0.73),
            .init(color: .black.opacity(0.22), location: 0.83),
            .init(color: .black.opacity(0.09), location: 0.92),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .frame(height: fixedHeight ?? CGFloat(style?.height ?? 96))
    }
}

// MARK: - 小号滑块（2026-09-25 她嫌系统滑块的胶囊钮太大）

struct SlimSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    var track: Color = Color.gray.opacity(0.28)
    var onCommit: () -> Void = {}

    private let thumbW: CGFloat = 26
    private let thumbH: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - thumbW)
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = CGFloat(min(1, max(0, t))) * usable
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: 4)
                Capsule().fill(tint).frame(width: x + thumbW / 2, height: 4)
                Capsule()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
                    .frame(width: thumbW, height: thumbH)
                    // 只有钮能抓（2026-09-25 她滑页面老误触）：轨道上别处按下去照常是滚页面。
                    // 钮的热区比画出来的大一圈，好抓
                    .contentShape(Rectangle().inset(by: -12))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("slimTrack"))
                        .onChanged { g in
                            let p = min(1, max(0, (g.location.x - thumbW / 2) / usable))
                            value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                        }
                        .onEnded { _ in onCommit() })
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(.named("slimTrack"))
        }
        .frame(height: 28)
    }
}

// MARK: - 取色器（2026-09-25：先是系统取色器点不开，再是固定色块不够自由——现在是一块
// 饱和度×明度的方板 + 一条色相条 + 色号输入，拖到哪算哪）

struct ColorGridSheet: View {
    let title: String
    let initial: Color
    /// final = 手松开了（该存了）；拖动途中只给预览看
    let onPick: (Color, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var h: Double = 0
    @State private var sat: Double = 0
    @State private var bri: Double = 1
    @State private var hex = ""
    @State private var hexBad = false
    @State private var typing = false

    private var current: Color { Color(hue: h, saturation: sat, brightness: bri) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(title).font(Typo.sans(Typo.Size.headline, .semibold))
                Spacer()
                Button("好") { dismiss() }.font(Typo.sans(Typo.Size.body, .semibold))
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(current)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 52, height: 36)
                HStack(spacing: 2) {
                    Text("#").font(Typo.number(Typo.Size.headline, .medium)).foregroundStyle(.secondary)
                    TextField("色号", text: $hex, onEditingChanged: { typing = $0 })
                        .font(Typo.number(Typo.Size.headline, .medium))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(applyHex)
                        .onChange(of: hex) { _, v in
                            let clean = String(v.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6))
                            if clean != v { hex = clean }
                            if typing, clean.count == 6 { applyHex() } else { hexBad = false }
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hexBad ? Color.red.opacity(0.6) : .clear, lineWidth: 1))
            }
            // 方板：横着是饱和度，竖着是明度
            GeometryReader { geo in
                let w = geo.size.width, ht = geo.size.height
                ZStack(alignment: .topLeading) {
                    Color(hue: h, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 3)
                        .background(Circle().fill(current))
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(width: 24, height: 24)
                        .offset(x: sat * w - 12, y: (1 - bri) * ht - 12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        sat = min(1, max(0, g.location.x / w))
                        bri = min(1, max(0, 1 - g.location.y / ht))
                        emit(final: false)
                    }
                    .onEnded { _ in emit(final: true) })
            }
            .frame(height: 190)
            // 色相条
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                        startPoint: .leading, endPoint: .trailing))
                        .frame(height: 14)
                    Circle()
                        .fill(Color(hue: h, saturation: 1, brightness: 1))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(width: 24, height: 24)
                        .offset(x: h * (w - 24))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        h = min(1, max(0, (g.location.x - 12) / max(1, w - 24)))
                        emit(final: false)
                    }
                    .onEnded { _ in emit(final: true) })
            }
            .frame(height: 28)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { load(initial) }
    }

    private func load(_ color: Color) {
        var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        UIColor(color).getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
        h = Double(hh); sat = Double(ss); bri = Double(bb)
        hex = color.hexString
    }

    private func emit(final: Bool) {
        if !typing { hex = current.hexString }
        onPick(current, final)
    }

    private func applyHex() {
        guard let color = Color(hex: hex) else { hexBad = true; return }
        hexBad = false
        let keep = hex
        load(color)
        hex = keep
        onPick(color, true)
    }
}

