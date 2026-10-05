import SwiftUI

// 移植自之前自用的 App MemoryDesk.swift 里的陈列板和洞洞板（Tilia 10-03：洞洞板移植自之前自用的 App；10-04：也要能翻面）。

/// 板子能翻面换材质（移植自之前自用的 App MemoryBoard；Lite 默认洞洞板）。
/// 三种材质：glass = 跟 Home 卡片同款磨砂玻璃；linen = 主题色布面板；peg = 宜家那种洞洞板。
/// 顶边正中一颗扁扁的小按钮，点一下板子绕竖轴翻个面换下一种（她要的），选的会记住。
/// 板子不是液态玻璃（frosted 是手画的材料），所以可以 3D 翻。
struct BoardSurface: View {
    @EnvironmentObject var theme: AppTheme
    @AppStorage("memoryBoardStyle") private var style: String = "peg"
    /// 翻面进行到哪了（度）。0→90 时换材质，再 -90→0 翻回来
    @State private var flip: Double = 0

    static let order = ["peg", "glass", "linen"]

    var body: some View {
        // 三面都一直在视图树里，只切透明度：磨砂材料是"第一次出现时"才开始渲染模糊的，
        // 翻到它那一面才建就会慢一拍（她 2026-09-24 看出来的）。没选中的留 0.001 不是 0——
        // 0 会被系统当成不用画直接跳过，材料又冷下去了。
        ZStack {
            ForEach(Self.order, id: \.self) { st in
                face(st).opacity(st == style ? 1 : 0.001)
            }
        }
            // 翻面用横向压扁（2D），不用 rotation3DEffect：带透视的 3D 变换会把整块拍平成一张图，
            // 磨砂材料在里面取不到背后的画面，翻的时候是没模糊的，停下来才补上——她看到的"闪一下"。
            // 压扁是普通仿射变换，材料照常实时模糊。再压一层随角度变深的暗面，看着还是在翻。
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .fill(Color.black.opacity(0.18 * abs(sin(flip * .pi / 180))))
                    .allowsHitTesting(false)
            }
            .scaleEffect(x: max(0.001, cos(flip * .pi / 180)), y: 1)
            .overlay(alignment: .top) {
                Button(action: turn) {
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 34, height: 7)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .frame(width: 64, height: 26)        // 热区比按钮本身大
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(y: -13)
                .accessibilityLabel("换陈列板材质")
            }
    }

    private func turn() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeIn(duration: 0.18)) { flip = 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let i = Self.order.firstIndex(of: style) ?? 0
            style = Self.order[(i + 1) % Self.order.count]
            flip = -90
            withAnimation(.easeOut(duration: 0.22)) { flip = 0 }
        }
    }

    @ViewBuilder
    private func face(_ style: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
        switch style {
        case "linen":
            ZStack {
                shape.fill(Color(hue: theme.hue / 360, saturation: 0.10, brightness: 0.95))
                // 布纹：极淡的经纬线
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)),
                                 with: .color(Color.white.opacity(0.22)))
                        y += 3
                    }
                    var x: CGFloat = 0
                    while x < size.width {
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)),
                                 with: .color(Color.black.opacity(0.035)))
                        x += 3
                    }
                }
                .clipShape(shape)
                // 一圈缝线
                RoundedRectangle(cornerRadius: Radii.card - 6, style: .continuous)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(7)
            }
            .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.10), radius: 10, y: 6)
        case "peg":
            PegboardFace()
        default:
            PhoneGlassCard(padding: 0, style: .frosted) {
                Color.clear.frame(maxHeight: .infinity)
            }
        }
    }
}

/// 洞洞板（宜家 SKÅDIS 那种）：一块白板挖出一格格竖着的长圆孔，行错开半格，四角四颗螺丝帽。
/// 2026-09-24 她：第一版孔太密看着起鸡皮疙瘩，孔拉稀；孔要真挖空透出壁纸（偶数填充把孔从板上抠掉），
/// 板子离墙有一点距离，所以影子也会从孔里露出来一点，看着是立体的。
struct PegboardFace: View {
    @EnvironmentObject var theme: AppTheme
    static let gapX: CGFloat = 46
    static let gapY: CGFloat = 42
    static let hole = CGSize(width: 6, height: 14)
    static let corner: CGFloat = 12

    /// 板子外形减去所有孔
    struct Board: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path(roundedRect: rect, cornerRadius: PegboardFace.corner, style: .continuous)
            for r in PegboardFace.holes(in: rect.size) {
                p.addPath(Path(roundedRect: r, cornerRadius: PegboardFace.hole.width / 2))
            }
            return p
        }
    }

    static func holes(in size: CGSize) -> [CGRect] {
        var out: [CGRect] = []
        let cols = max(1, Int((size.width - 36) / gapX))
        let rows = max(1, Int((size.height - 40) / gapY))
        // 整张孔阵在板上居中
        let spanX = CGFloat(cols) * gapX, spanY = CGFloat(rows) * gapY
        let x0 = (size.width - spanX) / 2, y0 = (size.height - spanY) / 2
        for row in 0...rows {
            let shift: CGFloat = row % 2 == 0 ? 0 : gapX / 2
            for col in 0...cols {
                let cx = x0 + CGFloat(col) * gapX + shift
                let cy = y0 + CGFloat(row) * gapY
                guard cx > 22, cx < size.width - 22, cy > 22, cy < size.height - 22 else { continue }
                out.append(CGRect(x: cx - hole.width / 2, y: cy - hole.height / 2,
                                  width: hole.width, height: hole.height))
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Board()
                    .fill(Color(hue: theme.hue / 360, saturation: 0.02, brightness: 0.985),
                          style: FillStyle(eoFill: true))
                    .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                    .shadow(color: .black.opacity(0.16), radius: 8, x: 2, y: 6)
                // 孔的上沿一道暗边：板有厚度
                Canvas { ctx, size in
                    for r in Self.holes(in: size) {
                        var edge = Path()
                        edge.addRoundedRect(in: r, cornerSize: CGSize(width: Self.hole.width / 2, height: Self.hole.width / 2))
                        ctx.stroke(edge, with: .color(Color.black.opacity(0.10)), lineWidth: 0.8)
                    }
                }
                // 四角的螺丝帽
                ForEach(0..<4, id: \.self) { i in
                    ZStack {
                        Circle().fill(Color(white: 0.96))
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        Capsule().fill(Color.black.opacity(0.18)).frame(width: 6, height: 1.2)
                            .rotationEffect(.degrees(Double(i) * 40 - 20))
                    }
                    .frame(width: 11, height: 11)
                    .position(x: i % 2 == 0 ? 12 : g.size.width - 12,
                              y: i < 2 ? 12 : g.size.height - 12)
                }
            }
        }
    }
}
