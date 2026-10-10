import SwiftUI
import PhotosUI

/// 我的气泡（2026-09-25）：左下角加号 →「我的气泡」。
///
/// 排版照Tilia自己画的设计图（预设 → 材质 → 颜色 → 玻璃 → 形状 → 位置），皮用我们自己的：
/// 卡片跟大脑设置同一套（浅色磨砂卡、深色手画玻璃）、花体英文小标题、主题色胶囊。
/// 右上角 ☀️/🌙 切的是**在改哪一套**，不动聊天页本身的深浅。
///
/// 滑块拖动时只改本页的草稿（顶上预览跟着动），松手才写进 AppStorage——
/// 每写一次聊天页整张列表都要重配一遍，拖着写会卡。
struct BubbleSettingsView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chatAppearance") private var appearanceRaw = ChatAppearance.light.rawValue   // 新用户默认浅色（Tilia 10-04）
    @AppStorage("chatDarkWallpaper") private var chatDarkWallpaper = false

    @State private var mode: ChatAppearance = .dark
    @State private var draft = BubbleStyle.darkSeed
    /// 这一套现在是不是「默认」（存的是空串）
    @State private var isDefault = true
    @State private var thought = ThoughtStyle()
    /// 顶部淡出雾；fadeIsDefault = 没调过（聊天页走原来那套）
    @State private var fade = FadeStyle()
    @State private var fadeIsDefault = true
    @State private var presets: [BubblePreset?] = [nil, nil, nil, nil]
    @State private var loaded = false

    @State private var namingSlot: Int?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var slotMenu: Int?
    /// 正在给哪一块选颜色（开色块取色器）
    @State private var colorTarget: ColorTarget?

    enum ColorTarget: String, Identifiable {
        case mu, mine, textMu, textMine, fade, thoughtInk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mu: return "对方的气泡"
            case .mine: return "我的气泡"
            case .textMu: return "对方的字"
            case .textMine: return "我的字"
            case .fade: return "顶部雾的颜色"
            case .thoughtInk: return "思考链的字"
            }
        }
    }

    // MARK: - 皮

    private var previewBubble: BubbleStyle? {
        isDefault ? BubbleStyle.effective(raw: "", mode: mode) : draft
    }
    private var skin: ChatSkin {
        ChatSkin(mode: mode, accent: theme.accent, scale: 1,
                 wallpaperInDark: chatDarkWallpaper, bubble: previewBubble)
    }
    private var sliderTrack: Color { skin.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10) }
    private var pillIdle: Color { Color.white.opacity(skin.isDark ? 0.08 : 0.35) }

    var body: some View {
        ZStack {
            pageBackground
            // 头钉在滚动区外面（2026-09-25 真机上 ☀️/🌙 点不动：放在 ScrollView 顶上那一截，
            // 离 sheet 上沿太近，点按被 sheet 的下拉手势吃掉了）
            VStack(spacing: 10) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                ScrollView {
                    VStack(spacing: 10) {
                        preview
                        presetsCard
                        colorCard
                        if draft.material == .glass { glassCard }
                        shapeCard
                        thoughtCard
                        fadeCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        // 页面的玻璃跟着「正在改的那一套」的深浅走：系统是浅色时深色页的材质会发白发灰
        .environment(\.colorScheme, mode == .dark ? .dark : .light)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            load(ChatAppearance(rawValue: appearanceRaw) ?? .dark)
        }
        .alert(renaming ? "改个名字" : "给这一格起个名字", isPresented: Binding(
            get: { namingSlot != nil }, set: { if !$0 { namingSlot = nil } })) {
            TextField("名字", text: $nameDraft)
            Button("好") { finishNaming() }
            Button("取消", role: .cancel) { namingSlot = nil }
        } message: {
            Text(renaming ? "" : "把现在调好的样子存进这一格")
        }
        .sheet(item: $colorTarget) { target in
            ColorGridSheet(title: target.title, initial: color(for: target)) { c, final in
                setColor(c, for: target, final: final)
            }
                .presentationDetents([.height(372)])
                .presentationBackground(.regularMaterial)
        }
        .confirmationDialog(slotMenu.flatMap { presets[$0]?.name } ?? "",
                            isPresented: Binding(get: { slotMenu != nil }, set: { if !$0 { slotMenu = nil } }),
                            titleVisibility: .visible) {
            if let i = slotMenu {
                Button("改名") {
                    nameDraft = presets[i]?.name ?? ""
                    renaming = true
                    namingSlot = i
                }
                Button("用现在的样子覆盖") {
                    presets[i]?.style = currentStyle
                    savePresets()
                }
                Button("清空这一格", role: .destructive) {
                    presets[i] = nil
                    savePresets()
                }
            }
        }
    }

    @ViewBuilder
    private var pageBackground: some View {
        if let bg = skin.pageBackground {
            bg.ignoresSafeArea()
        } else {
            AppBackground(choiceOverride: theme.chatBgChoice != "same" ? theme.chatBgChoice : nil,
                          darkVeil: skin.darkVeil)
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack {
            roundButton("xmark") { dismiss() }
            Spacer()
            VStack(spacing: 2) {
                Text("我的气泡")
                    .font(Typo.sans(Typo.Size.headline, .semibold))
                    .foregroundStyle(skin.ink)
                Text(mode == .dark ? "正在改：深色" : "正在改：浅色")
                    .font(Typo.sans(Typo.Size.caption))
                    .foregroundStyle(skin.inkDim)
            }
            Spacer()
            roundButton(mode == .dark ? "moon.fill" : "sun.max.fill") {
                load(mode == .dark ? .light : .dark)
            }
        }
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Typo.icon(15, .semibold))
                .foregroundStyle(skin.chromeIcon)
                .frame(width: 38, height: 38)
                .background(paintedChrome(Circle(), skin: skin))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 预览

    private var preview: some View {
        VStack(alignment: .leading, spacing: CGFloat(draft.rowSpacing) * 0.5) {
            if draft.layout == .header {
                AvatarView(who: .ai, size: 26)
            }
            // 顺序照聊天页：先「已思考」，头像在旁边时头像挨着它，气泡在下面缩进对齐
            HStack(alignment: .center, spacing: 6) {
                if draft.layout == .side { AvatarView(who: .ai, size: 26) }
                Text("› ✦ 想了想")
                    .font(Typo.sans(Typo.Size.caption))
                    .foregroundStyle(thought.inkColor(fallback: skin.inkDim))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(ThoughtPanelBackground(skin: skin, style: thought))
                Spacer()
            }
            sampleRow(mine: false, text: "今天想你了", avatar: false)
            sampleRow(mine: false, text: "什么时候回来", avatar: false)
            if draft.layout == .header {
                HStack { Spacer(); AvatarView(who: .me, size: 26) }
            }
            sampleRow(mine: true, text: "马上！等我", avatar: true)
        }
        .padding(12)
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
        // 顶部淡出雾也挂在预览上（按比例缩矮），调的时候看得见
        .overlay(alignment: .top) {
            TopFadeOverlay(isDark: skin.isDark, style: fadeIsDefault ? nil : fade,
                           fixedHeight: CGFloat(fadeIsDefault ? 96 : fade.height) * 0.6)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radii.card, topTrailingRadius: Radii.card,
                                                  style: .continuous))
                .allowsHitTesting(false)
        }
        .background {
            ZStack {
                if let bg = skin.pageBackground {
                    bg
                } else {
                    AppBackground(choiceOverride: theme.chatBgChoice != "same" ? theme.chatBgChoice : nil,
                                  darkVeil: skin.darkVeil)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
            .strokeBorder(Color.white.opacity(skin.isDark ? 0.12 : 0.6), lineWidth: 0.75))
    }

    private func sampleRow(mine: Bool, text: String, avatar: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if mine { Spacer(minLength: 30) }
            if !mine, draft.layout == .side { sideSlot(show: avatar, mine: false) }
            Text(text)
                .font(Typo.sans(Typo.Size.body))
                .foregroundStyle(skin.bubbleInk(mine: mine))
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(ChatBubbleBackground(skin: skin, mine: mine))
            if mine, draft.layout == .side { sideSlot(show: avatar, mine: true) }
            if !mine { Spacer(minLength: 30) }
        }
    }

    private func sideSlot(show: Bool, mine: Bool) -> some View {
        Group {
            if show { AvatarView(who: mine ? .me : .ai, size: 26).frame(width: 26, height: 26) }
            else { Color.clear.frame(width: 26, height: 0) }
        }
    }

    // MARK: - 预设

    private var presetsCard: some View {
        card("presets") {
            HStack(spacing: 8) {
                if mode == .dark {
                    // 深色前两格固定（2026-09-25 Tilia）：无背景 / 有背景，都是原来那套画法，
                    // 点了顺手把「深色也铺壁纸」切过去；自己存的只剩三格
                    presetTile(name: "无背景", style: nil, wallpaper: false,
                               selected: isDefault && !chatDarkWallpaper) {
                        chatDarkWallpaper = false
                        resetToDefault()
                    }
                    presetTile(name: "有背景", style: nil, wallpaper: true,
                               selected: isDefault && chatDarkWallpaper) {
                        chatDarkWallpaper = true
                        resetToDefault()
                    }
                } else {
                    presetTile(name: "默认", style: BubbleStyle.effective(raw: "", mode: mode),
                               selected: isDefault) {
                        resetToDefault()
                    }
                }
                ForEach(0..<(mode == .dark ? 3 : 4), id: \.self) { i in
                    if let p = presets[i] {
                        presetTile(name: p.name, style: p.style,
                                   selected: !isDefault && draft == p.style) {
                            apply(p.style)
                        }
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            slotMenu = i
                        })
                    } else {
                        emptyTile {
                            nameDraft = ""
                            renaming = false
                            namingSlot = i
                        }
                    }
                }
            }
            hint("点空格把现在的样子存进去；长按有名字的格子改名、覆盖或清空。")
        }
    }

    private func presetTile(name: String, style: BubbleStyle?, wallpaper: Bool? = nil, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        let tileSkin = ChatSkin(mode: mode, accent: theme.accent, scale: 1,
                                wallpaperInDark: wallpaper ?? chatDarkWallpaper, bubble: style)
        return Button(action: action) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    ChatBubbleBackground(skin: tileSkin, mine: false).frame(width: 30, height: 11)
                    HStack { Spacer(minLength: 0)
                        ChatBubbleBackground(skin: tileSkin, mine: true).frame(width: 24, height: 11) }
                }
                .frame(width: 36)
                Text(name)
                    .font(Typo.sans(Typo.Size.caption, .medium))
                    .foregroundStyle(selected ? skin.ink : skin.inkDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .fill(pillIdle)
                RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .strokeBorder(selected ? theme.accent : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func emptyTile(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(Typo.icon(13, .semibold))
                    .foregroundStyle(skin.inkFaint)
                    .frame(height: 25)
                Text("空")
                    .font(Typo.sans(Typo.Size.caption))
                    .foregroundStyle(skin.inkFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .strokeBorder(skin.inkFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 材质


    // MARK: - 颜色

    private var colorCard: some View {
        card("bubble") {
            pills(BubbleStyle.Material.allCases, selected: draft.material, label: \.label) { m in
                edit { $0.material = m }
            }
            colorRow("主颜色", mu: .mu, mine: .mine)
            colorRow("文字颜色", mu: .textMu, mine: .textMine)
            slider("透明度", value: \.transparency, range: 0...0.95) { "\(Int(($0 * 100).rounded()))%" }
        }
    }

    private func colorRow(_ title: String, mu: ColorTarget, mine: ColorTarget) -> some View {
        HStack {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(skin.ink)
            Spacer()
            swatch("对方", target: mu)
            swatch("我", target: mine)
        }
    }

    /// 圆色块：点开色块取色器（带色号输入）
    private func swatch(_ who: String, target: ColorTarget) -> some View {
        Button { colorTarget = target } label: {
            HStack(spacing: 5) {
                if !who.isEmpty {
                    Text(who).font(Typo.sans(Typo.Size.caption)).foregroundStyle(skin.inkDim)
                }
                Circle().fill(color(for: target))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .frame(width: 26, height: 26)
            }
            .padding(.leading, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(for target: ColorTarget) -> Color {
        switch target {
        case .mu: return draft.fill(mine: false, accent: theme.accent)
        case .mine: return draft.fill(mine: true, accent: theme.accent)
        case .textMu: return draft.ink(mine: false, fallback: skin.ink)
        case .textMine: return draft.ink(mine: true, fallback: skin.ink)
        case .fade: return Color(hex: fade.color) ?? .white
        case .thoughtInk: return thought.inkColor(fallback: skin.inkDim)
        }
    }

    /// 拖着取色时只改草稿（预览跟着动），手松开（final）才存——跟滑块一个道理
    private func setColor(_ c: Color, for target: ColorTarget, final: Bool) {
        let hex = c.hexString
        switch target {
        case .fade:
            fade.color = hex
            fadeIsDefault = false
            if final { saveFade() }
            return
        case .thoughtInk:
            thought.ink = hex
            if final { saveThought() }
            return
        case .mu: draft.colorMu = hex
        case .mine: draft.colorMine = hex
        case .textMu: draft.textMu = hex
        case .textMine: draft.textMine = hex
        }
        isDefault = false
        if final { save() }
    }

    // MARK: - 玻璃

    private var glassCard: some View {
        card("glass") {
            slider("模糊", value: \.blur, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
            slider("亮度", value: \.brightness, range: -0.3...0.3) { "\(Int(((1 + $0) * 100).rounded()))%" }
            slider("边框光", value: \.edgeLight, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
            toggleRow("内侧高光", isOn: \.highlight)
            hint("模糊低、边框光高 → 液态玻璃；模糊高、边框光低 → 毛玻璃。")
        }
    }

    // MARK: - 形状

    private var shapeCard: some View {
        card("shape") {
            slider("圆角", value: \.cornerRadius, range: 4...24) { "\(Int($0.rounded()))" }
            slider("间距", value: \.rowSpacing, range: 2...24) { "\(Int($0.rounded()))" }
            slider("长度", value: \.lengthKnob, range: 0...60) { "\(Int($0.rounded()))" }
            toggleRow("气泡尾巴", isOn: \.tail)
            layoutPicker
        }
    }

    // MARK: - 位置

    private var layoutPicker: some View {
        HStack(spacing: 8) {
                ForEach(BubbleStyle.Layout.allCases, id: \.self) { layout in
                    let picked = draft.layout == layout
                    Button {
                        edit { $0.layout = layout }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: layout.icon).font(Typo.icon(12))
                            Text(layout.label).font(Typo.sans(Typo.Size.caption, .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(picked ? .white : skin.inkDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(picked ? AnyShapeStyle(theme.accent) : AnyShapeStyle(pillIdle)))
                    }
                    .buttonStyle(.plain)
                }
        }
    }

    // MARK: - 思考链

    private var thoughtCard: some View {
        card("thinking") {
            thoughtSlider("透明度", value: \.transparency, range: 0...0.9) { "\(Int(($0 * 100).rounded()))%" }
            thoughtSlider("亮度", value: \.brightness, range: -0.3...0.3) { "\(Int(((1 + $0) * 100).rounded()))%" }
            thoughtSlider("亮边", value: \.edgeLight, range: 0...1) { $0 < 0.01 ? "无" : "\(Int(($0 * 100).rounded()))%" }
            // 小字颜色（10-04 Tilia：深色模式配浅底板时看不清）
            HStack(spacing: 10) {
                Text("字的颜色").font(Typo.sans(Typo.Size.body)).foregroundStyle(skin.ink)
                Spacer()
                if thought.ink != nil {
                    Button("跟着皮肤") {
                        thought.ink = nil
                        saveThought()
                    }
                    .font(Typo.sans(Typo.Size.caption))
                    .foregroundStyle(skin.inkDim)
                    .buttonStyle(.plain)
                }
                swatch("", target: .thoughtInk)
            }
            if thought != ThoughtStyle() {
                HStack {
                    Spacer()
                    Button("恢复原样") {
                        thought = ThoughtStyle()
                        UserDefaults.standard.set("", forKey: ThoughtStyle.key(mode))
                    }
                    .font(Typo.sans(Typo.Size.callout, .semibold))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 顶部淡出

    private var fadeCard: some View {
        card("top fade") {
            fadeSlider("模糊", \.blur, 0...1) { "\(Int(($0 * 100).rounded()))%" }
            fadeSlider("明度", \.brightness, -0.5...0.5) { "\(Int(((1 + $0) * 100).rounded()))%" }
            HStack(spacing: 10) {
                Text("颜色").font(Typo.sans(Typo.Size.body)).foregroundStyle(skin.ink)
                    .frame(width: 50, alignment: .leading)
                SlimSlider(value: Binding(get: { fade.colorAmount },
                                          set: { fade.colorAmount = $0; fadeIsDefault = false }),
                           range: 0...1, tint: theme.accent, track: sliderTrack) { saveFade() }
                Text("\(Int((fade.colorAmount * 100).rounded()))%")
                    .font(Typo.number(Typo.Size.callout, .medium)).foregroundStyle(skin.inkDim)
                    .frame(width: 40, alignment: .trailing)
                swatch("", target: .fade)
            }
            fadeSlider("饱和度", \.saturation, 0...2) { "\(Int(($0 * 100).rounded()))%" }
            fadeSlider("高度", \.height, 40...200) { "\(Int($0.rounded()))" }
            HStack {
                hint("消息滑到最上面时蒙的那层雾。")
                Spacer()
                if !fadeIsDefault {
                    Button("恢复原样") { resetFade() }
                        .font(Typo.sans(Typo.Size.callout, .semibold))
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func fadeSlider(_ title: String, _ value: WritableKeyPath<FadeStyle, Double>,
                            _ range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        sliderBody(title, text: format(fade[keyPath: value]),
                   binding: Binding(get: { fade[keyPath: value] },
                                    set: { fade[keyPath: value] = $0; fadeIsDefault = false }),
                   range: range) { saveFade() }
    }

    private func thoughtSlider(_ title: String, value: WritableKeyPath<ThoughtStyle, Double>,
                               range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        sliderBody(title, text: format(thought[keyPath: value]),
                   binding: Binding(get: { thought[keyPath: value] },
                                    set: { thought[keyPath: value] = $0 }),
                   range: range) { saveThought() }
    }

    // MARK: - 零件

    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let inner = VStack(alignment: .leading, spacing: 9) {
            Text(title).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(skin.inkDim)
            content()
        }
        if skin.isDark {
            inner
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // 深色铺壁纸时手画玻璃压在灰壁纸上会发白、字看不清，垫一层黑
                    let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    ZStack {
                        paintedChrome(shape, skin: skin)
                        if skin.darkVeil { shape.fill(Color.black.opacity(0.25)) }
                    }
                }
        } else {
            PhoneGlassCard(padding: 14, style: .frosted) { inner }
        }
    }

    private var divider: some View {
        Rectangle().fill(skin.inkFaint.opacity(0.25)).frame(height: 0.5)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Typo.sans(Typo.Size.caption))
            .foregroundStyle(skin.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pills<T: Hashable>(_ items: [T], selected: T, label: KeyPath<T, String>,
                                    pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let picked = item == selected
                Button { pick(item) } label: {
                    Text(item[keyPath: label])
                        .font(Typo.sans(Typo.Size.callout, .semibold))
                        .foregroundStyle(picked ? .white : skin.inkDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(picked ? AnyShapeStyle(theme.accent) : AnyShapeStyle(pillIdle)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func slider(_ title: String, value: WritableKeyPath<BubbleStyle, Double>,
                        range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        sliderBody(title, text: format(draft[keyPath: value]),
                   binding: Binding(get: { draft[keyPath: value] },
                                    set: { v in
                                        draft[keyPath: value] = v
                                        isDefault = false
                                    }),
                   range: range) { save() }
    }

    private func sliderBody(_ title: String, text: String, binding: Binding<Double>,
                            range: ClosedRange<Double>, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(skin.ink)
                .frame(width: 50, alignment: .leading)
            SlimSlider(value: binding, range: range, tint: theme.accent, track: sliderTrack, onCommit: commit)
            Text(text).font(Typo.number(Typo.Size.callout, .medium)).foregroundStyle(skin.inkDim)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func toggleRow(_ title: String, isOn: WritableKeyPath<BubbleStyle, Bool>) -> some View {
        HStack {
            Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(skin.ink)
            Spacer()
            Toggle("", isOn: Binding(get: { draft[keyPath: isOn] },
                                     set: { v in edit { $0[keyPath: isOn] = v } }))
                .labelsHidden()
                .tint(theme.accent)
        }
    }

    // MARK: - 存取

    /// 现在这一套真正长什么样（存进预设格用）
    private var currentStyle: BubbleStyle {
        isDefault ? seed(for: mode) : draft
    }

    /// 「默认」时各个控件停在哪。深色铺了壁纸时老画法其实是玻璃（浅色系毛玻璃糊 50% 再染黑，
    /// 我这侧是主题色沉八成进黑），照着它起步，材质那一栏才不会指着「半透明」说瞎话
    private func seed(for mode: ChatAppearance) -> BubbleStyle {
        guard mode == .dark, chatDarkWallpaper else { return BubbleStyle.seed(for: mode) }
        var s = BubbleStyle.darkSeed
        s.material = .glass
        s.colorMu = "000000"
        s.colorMine = ChatSkin.blend(theme.accent, toward: .black, 0.80).hexString
        s.transparency = 0.45
        s.blur = 0.3
        s.brightness = 0
        s.highlight = false
        s.edgeLight = 0.1
        return s
    }

    private func load(_ newMode: ChatAppearance) {
        mode = newMode
        let raw = UserDefaults.standard.string(forKey: BubbleStyle.storageKey(newMode)) ?? ""
        if let style = BubbleStyle.decode(raw) {
            draft = style
            isDefault = false
        } else {
            draft = seed(for: newMode)
            isDefault = true
        }
        thought = ThoughtStyle.decode(UserDefaults.standard.string(forKey: ThoughtStyle.key(newMode)) ?? "")
        if let saved = FadeStyle.decode(UserDefaults.standard.string(forKey: FadeStyle.key(newMode)) ?? "") {
            fade = saved
            fadeIsDefault = false
        } else {
            fade = FadeStyle.seed(for: newMode)
            fadeIsDefault = true
        }
        presets = BubblePreset.decodeList(UserDefaults.standard.string(forKey: BubbleStyle.presetsKey(newMode)) ?? "")
    }

    /// 点选类的改动：当场存
    private func edit(_ change: (inout BubbleStyle) -> Void) {
        change(&draft)
        isDefault = false
        save()
    }

    private func save() {
        UserDefaults.standard.set(draft.encoded(), forKey: BubbleStyle.storageKey(mode))
    }

    private func saveFade() {
        UserDefaults.standard.set(fade.encoded(), forKey: FadeStyle.key(mode))
    }

    private func resetFade() {
        UserDefaults.standard.set("", forKey: FadeStyle.key(mode))
        fade = FadeStyle.seed(for: mode)
        fadeIsDefault = true
    }

    private func saveThought() {
        UserDefaults.standard.set(thought.encoded(), forKey: ThoughtStyle.key(mode))
    }

    private func apply(_ style: BubbleStyle) {
        draft = style
        isDefault = false
        save()
    }

    private func resetToDefault() {
        UserDefaults.standard.set("", forKey: BubbleStyle.storageKey(mode))
        draft = seed(for: mode)
        isDefault = true
    }

    private func savePresets() {
        UserDefaults.standard.set(BubblePreset.encodeList(presets), forKey: BubbleStyle.presetsKey(mode))
    }

    private func finishNaming() {
        guard let i = namingSlot else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "预设\(i + 1)" : String(name.prefix(6))
        if renaming {
            presets[i]?.name = finalName
        } else {
            presets[i] = BubblePreset(name: finalName, style: currentStyle)
        }
        namingSlot = nil
        renaming = false
        savePresets()
    }
}


/// 聊天壁纸（2026-09-25 从 Me 页搬到 ⋯ 面板：外观那一行的小圆钮点进来）。
/// 内容照 Me 页原来那张卡：跟随全局 / 自带几张 / 她自己导入的（长按删）/ 导入，外加「深色也铺壁纸」。
struct ChatWallpaperSheet: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chatDarkWallpaper") private var chatDarkWallpaper = false
    @State private var pickerItem: PhotosPickerItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("聊天壁纸").font(Typo.sans(Typo.Size.headline, .semibold))
                Spacer()
                Button("好") { dismiss() }.font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.accent)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("深色也铺壁纸").font(Typo.sans(Typo.Size.body))
                    Text("关着深色是纯黑").font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $chatDarkWallpaper).labelsHidden().tint(theme.accent)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {

                    ForEach(AppTheme.backgrounds, id: \.id) { bg in cell(bg.id) }
                    ForEach(theme.chatCustomBackgrounds, id: \.self) { name in
                        cell(name)
                            .contextMenu {
                                Button(role: .destructive) {
                                    theme.removeChatCustomBackground(name)
                                } label: { Label("删除这张", systemImage: "trash") }
                            }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .aspectRatio(0.66, contentMode: .fit)
                            .overlay(VStack(spacing: 4) {
                                Image(systemName: "plus").font(Typo.icon(20))
                                Text("导入").font(Typo.sans(Typo.Size.caption))
                            }.foregroundStyle(theme.accent))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.85) {
                    theme.addChatCustomBackground(jpeg)
                }
                pickerItem = nil
            }
        }
    }

    private func cell(_ id: String) -> some View {
        let selected = theme.chatBgChoice == id
        return thumb(id)
            .aspectRatio(0.66, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? theme.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            }
            .overlay(alignment: .bottom) {
                if id == "same" {
                    Text("跟随全局").font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary).padding(.bottom, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) { theme.chatBgChoice = id }
            }
    }

    @ViewBuilder
    private func thumb(_ id: String) -> some View {
        Color.clear.overlay {
            if id == "cloud" {
                AppTheme.cloudGradient
            } else if id == "plain" {
                AppTheme.plainColor
            } else if id == "same" {
                Color.primary.opacity(0.05)
                    .overlay(Image(systemName: "circle.grid.2x2").font(Typo.icon(18)).foregroundStyle(.secondary))
            } else if let image = UIImage(contentsOfFile: AppTheme.bgDir.appendingPathComponent(id).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .clipped()
    }
}
