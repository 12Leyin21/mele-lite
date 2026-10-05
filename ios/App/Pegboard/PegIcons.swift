import SwiftUI

// MARK: - 洞洞板上的四件（Tilia 10-03 定稿：信 / 地图照第三版草图，相册 / 记录照第四版）
//
// 坐标照草图的 SVG 抄过来（以图标中心为原点），画的时候整体按宽缩放。
// 配色只用主题色和它往白里调淡的几档：最深 = 主题色，其他只往淡走（她定的）。
// 体积只靠外面那两层淡影子，不画高光、不做果冻感。

extension AppTheme {
    /// 主题色往白里调淡：0 = 主题色本身，1 = 白
    func wash(_ t: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = CGFloat(t)
        return Color(red: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k)
    }
    /// 纸边那种很淡的暖灰（草图里的 #E5E3DC / #EFEDE7）
    var paperLine: Color { Color(hue: hue / 360, saturation: 0.03, brightness: 0.89) }
    var paperLineSoft: Color { Color(hue: hue / 360, saturation: 0.02, brightness: 0.93) }
}

/// 一件图标的设计框：原点在框里的哪儿、框多大（草图坐标）
struct IconBox {
    let ox: CGFloat, oy: CGFloat, w: CGFloat, h: CGFloat
    var aspect: CGFloat { w / h }
}

/// 在草图坐标里画：把 ctx 挪到原点、按宽缩放
private func drawing(_ box: IconBox, _ ctx: inout GraphicsContext, _ size: CGSize) {
    let k = size.width / box.w
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: box.ox, y: box.oy)
}

/// 草图坐标里的形状（给毛玻璃信封、点击区域用）
struct BoxShape: Shape {
    let box: IconBox
    let build: (inout Path) -> Void
    func path(in rect: CGRect) -> Path {
        var p = Path()
        build(&p)
        let k = rect.width / box.w
        return p.applying(CGAffineTransform(translationX: box.ox, y: box.oy).concatenating(.init(scaleX: k, y: k)))
    }
}

// MARK: 信：半透明（真毛玻璃）信封，正面朝上，右上斜贴一枚锯齿邮票

struct LetterIcon: View {
    @EnvironmentObject private var theme: AppTheme
    static let box = IconBox(ox: 72, oy: 48, w: 148, h: 100)

    private var envelope: BoxShape {
        BoxShape(box: Self.box) { $0.addRoundedRect(in: CGRect(x: -70, y: -44, width: 140, height: 90), cornerSize: CGSize(width: 8, height: 8)) }
    }

    var body: some View {
        ZStack {
            // 跟别的几件一样白，留一点点透（10-04 Tilia：毛玻璃那版看着发灰）
            envelope.fill(Color.white.opacity(0.86))
            envelope.stroke(theme.paperLine, lineWidth: 1)
            Canvas { ctx, size in
                drawing(Self.box, &ctx, size)
                var flap = Path()
                flap.move(to: CGPoint(x: -68, y: -42)); flap.addLine(to: CGPoint(x: 0, y: 6)); flap.addLine(to: CGPoint(x: 68, y: -42))
                ctx.stroke(flap, with: .color(theme.paperLine), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                var folds = Path()
                folds.move(to: CGPoint(x: -68, y: 44)); folds.addLine(to: CGPoint(x: -20, y: 6))
                folds.move(to: CGPoint(x: 68, y: 44)); folds.addLine(to: CGPoint(x: 20, y: 6))
                ctx.stroke(folds, with: .color(theme.paperLineSoft), lineWidth: 1.2)

                // 邮票
                var s = ctx
                s.translateBy(x: 42, y: -14)
                s.rotate(by: .degrees(6))
                let stamp = Self.stampPath(CGRect(x: -19, y: -22, width: 36, height: 42), bite: 3, step: 6)
                s.drawLayer { l in
                    l.addFilter(.shadow(color: .black.opacity(0.10), radius: 1.2, x: 0, y: 1))
                    l.fill(stamp, with: .color(.white))
                }
                s.stroke(stamp, with: .color(theme.accent), lineWidth: 1.5)
                let inner = Path(roundedRect: CGRect(x: -13, y: -16, width: 28, height: 30), cornerRadius: 1)
                s.fill(inner, with: .color(theme.wash(0.86)))
                s.stroke(inner, with: .color(theme.accent), lineWidth: 1)
                var heart = Path()
                heart.move(to: CGPoint(x: 1, y: 7))
                heart.addCurve(to: CGPoint(x: -3, y: -6), control1: CGPoint(x: -6, y: 1), control2: CGPoint(x: -7, y: -4))
                heart.addCurve(to: CGPoint(x: 1, y: -3), control1: CGPoint(x: -1, y: -7), control2: CGPoint(x: 1, y: -5))
                heart.addCurve(to: CGPoint(x: 5, y: -6), control1: CGPoint(x: 1, y: -5), control2: CGPoint(x: 3, y: -7))
                heart.addCurve(to: CGPoint(x: 1, y: 7), control1: CGPoint(x: 9, y: -4), control2: CGPoint(x: 8, y: 1))
                heart.closeSubpath()
                s.fill(heart, with: .color(theme.accent))
            }
        }
        .aspectRatio(Self.box.aspect, contentMode: .fit)
    }

    /// 邮票：方框四边每隔 step 咬掉一个半圆（齿孔）
    static func stampPath(_ r: CGRect, bite: CGFloat, step: CGFloat) -> Path {
        var holes = Path()
        func hole(_ x: CGFloat, _ y: CGFloat) { holes.addEllipse(in: CGRect(x: x - bite, y: y - bite, width: bite * 2, height: bite * 2)) }
        var x = r.minX + bite
        while x <= r.maxX - bite + 0.1 { hole(x, r.minY); hole(x, r.maxY); x += step }
        var y = r.minY + bite
        while y <= r.maxY - bite + 0.1 { hole(r.minX, y); hole(r.maxX, y); y += step }
        return Path(r).subtracting(holes)
    }
}

// MARK: 相册：两张竖版拍立得错开叠着，相框上印主题色波点，顶上一颗图钉

struct AlbumIcon: View {
    @EnvironmentObject private var theme: AppTheme
    var photo: UIImage?
    static let box = IconBox(ox: 64, oy: 84, w: 128, h: 152)

    var body: some View {
        Canvas { ctx, size in
            drawing(Self.box, &ctx, size)
            card(&ctx, angle: -8, dx: -12, dy: 4, photoFill: theme.wash(0.86), front: false)
            card(&ctx, angle: 5, dx: 10, dy: -2, photoFill: theme.wash(0.62), front: true)
            // 图钉
            ctx.fill(Path(ellipseIn: CGRect(x: 6, y: -60, width: 12, height: 4)), with: .color(.black.opacity(0.10)))
            var needle = Path()
            needle.move(to: CGPoint(x: 10, y: -66)); needle.addLine(to: CGPoint(x: 12, y: -58))
            ctx.stroke(needle, with: .color(theme.wash(0.35)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 2.5, y: -77.5, width: 15, height: 15)), with: .color(theme.accent))
            ctx.fill(Path(ellipseIn: CGRect(x: 5.3, y: -74.7, width: 4.4, height: 4.4)), with: .color(.white.opacity(0.75)))
        }
        .aspectRatio(Self.box.aspect, contentMode: .fit)
    }

    private func card(_ ctx: inout GraphicsContext, angle: Double, dx: CGFloat, dy: CGFloat, photoFill: Color, front: Bool) {
        var c = ctx
        c.rotate(by: .degrees(angle))
        c.translateBy(x: dx, y: dy)
        let frame = Path(roundedRect: CGRect(x: -44, y: -54, width: 88, height: 108), cornerRadius: 2)
        c.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(front ? 0.10 : 0.07), radius: 2.5, x: 0, y: 2))
            l.fill(frame, with: .color(.white))
        }
        // 波点（只印在相框上，照片盖住的地方看不见）
        c.drawLayer { l in
            l.clip(to: frame)
            var dots = Path()
            var y: CGFloat = -54
            var row = 0
            while y < 56 {
                var x: CGFloat = -44 + (row % 2 == 0 ? 3 : 8.5)
                while x < 46 { dots.addEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)); x += 11 }
                y += 5.5; row += 1
            }
            l.fill(dots, with: .color(theme.accent.opacity(0.55)))
        }
        c.stroke(frame, with: .color(theme.paperLineSoft), lineWidth: 1)
        let window = CGRect(x: -37, y: -47, width: 74, height: 74)
        if front, let photo {
            c.drawLayer { l in
                l.clip(to: Path(window))
                let s = photo.size
                let k = max(window.width / s.width, window.height / s.height)
                let r = CGRect(x: window.midX - s.width * k / 2, y: window.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
                l.draw(Image(uiImage: photo), in: r)
            }
        } else {
            c.fill(Path(window), with: .color(photoFill))
            if front {
                c.fill(Path(ellipseIn: CGRect(x: 8, y: -36, width: 16, height: 16)), with: .color(.white.opacity(0.85)))
                var hill = Path()
                hill.move(to: CGPoint(x: -37, y: 27)); hill.addLine(to: CGPoint(x: -14, y: 2)); hill.addLine(to: CGPoint(x: 2, y: 16))
                hill.addLine(to: CGPoint(x: 14, y: 6)); hill.addLine(to: CGPoint(x: 37, y: 24)); hill.addLine(to: CGPoint(x: 37, y: 27)); hill.closeSubpath()
                c.fill(hill, with: .color(theme.wash(0.35)))
            }
        }
    }
}

// MARK: 记录：照之前自用的 App档案袋——上面一片封口、两角小星星、两颗纽扣绕线、夹缝里戳出主题色小标签

struct RecordIcon: View {
    @EnvironmentObject private var theme: AppTheme
    static let box = IconBox(ox: 48, oy: 62, w: 96, h: 124)

    var body: some View {
        Canvas { ctx, size in
            drawing(Self.box, &ctx, size)
            let body = Path(roundedRect: CGRect(x: -46, y: -60, width: 92, height: 120), cornerRadius: 3)
            ctx.fill(body, with: .color(.white))
            ctx.stroke(body, with: .color(theme.paperLine), lineWidth: 1.2)
            // 小标签：压在封口底下，从封口和袋身的夹缝里往下戳出一截
            var tab = Path()
            tab.move(to: CGPoint(x: 18, y: -26)); tab.addLine(to: CGPoint(x: 34, y: -26))
            tab.addLine(to: CGPoint(x: 34, y: -10))
            tab.addArc(center: CGPoint(x: 32, y: -10), radius: 2, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            tab.addLine(to: CGPoint(x: 20, y: -8))
            tab.addArc(center: CGPoint(x: 20, y: -10), radius: 2, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            tab.closeSubpath()
            ctx.fill(tab, with: .color(theme.accent))
            var flap = Path()
            flap.move(to: CGPoint(x: -46, y: -60)); flap.addLine(to: CGPoint(x: 46, y: -60)); flap.addLine(to: CGPoint(x: 46, y: -30))
            flap.addLine(to: CGPoint(x: 34, y: -18)); flap.addLine(to: CGPoint(x: -34, y: -18)); flap.addLine(to: CGPoint(x: -46, y: -30)); flap.closeSubpath()
            ctx.fill(flap, with: .color(.white))
            ctx.stroke(flap, with: .color(theme.paperLine), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            // 底部折边
            var fold = Path()
            fold.move(to: CGPoint(x: -46, y: 44)); fold.addLine(to: CGPoint(x: -34, y: 34)); fold.addLine(to: CGPoint(x: 34, y: 34)); fold.addLine(to: CGPoint(x: 46, y: 44))
            ctx.stroke(fold, with: .color(theme.paperLineSoft), lineWidth: 1.2)
            // 两角小星星
            ctx.fill(Self.star(center: CGPoint(x: -38, y: -45.6), r: 4.6), with: .color(theme.wash(0.35)))
            ctx.fill(Self.star(center: CGPoint(x: 36, y: -46.2), r: 4.0), with: .color(theme.wash(0.35)))
            // 标签框
            ctx.stroke(Path(CGRect(x: -34, y: -6, width: 36, height: 44)), with: .color(theme.wash(0.62)), lineWidth: 1)
            // 绕线
            var thread = Path()
            thread.move(to: CGPoint(x: 0, y: -26))
            thread.addCurve(to: CGPoint(x: 0, y: 2), control1: CGPoint(x: 10, y: -18), control2: CGPoint(x: -10, y: -6))
            thread.addCurve(to: CGPoint(x: 0, y: -26), control1: CGPoint(x: 10, y: -6), control2: CGPoint(x: -10, y: -18))
            ctx.stroke(thread, with: .color(theme.accent.opacity(0.8)), lineWidth: 1)
            for y in [-26.0, 2.0] as [CGFloat] {
                let b = Path(ellipseIn: CGRect(x: -5.5, y: y - 5.5, width: 11, height: 11))
                ctx.fill(b, with: .color(theme.wash(0.62)))
                ctx.stroke(b, with: .color(theme.wash(0.35)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: -1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(.white))
            }
        }
        .aspectRatio(Self.box.aspect, contentMode: .fit)
    }

    static func star(center c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            let rr = i % 2 == 0 ? r : r * 0.45
            let pt = CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: 地图：三折半摊开的纸地图，一条主题色虚线通向定位针（进线下模式）；顶上一截和纸胶带把它粘在板上（10-04 Tilia）

struct MapIcon: View {
    @EnvironmentObject private var theme: AppTheme
    static let box = IconBox(ox: 62, oy: 58, w: 122, h: 122)

    var body: some View {
        Canvas { ctx, size in
            drawing(Self.box, &ctx, size)
            func panel(_ pts: [CGPoint], _ fill: Color) {
                var p = Path()
                p.addLines(pts); p.closeSubpath()
                ctx.fill(p, with: .color(fill))
                ctx.stroke(p, with: .color(theme.paperLine), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
            panel([.init(x: -60, y: -32), .init(x: -20, y: -44), .init(x: -20, y: 44), .init(x: -60, y: 54)], .white)
            panel([.init(x: -20, y: -44), .init(x: 20, y: -32), .init(x: 20, y: 56), .init(x: -20, y: 44)],
                  Color(hue: theme.hue / 360, saturation: 0.02, brightness: 0.97))
            panel([.init(x: 20, y: -32), .init(x: 54, y: -46), .init(x: 52, y: 42), .init(x: 20, y: 56)], .white)
            var route = Path()
            route.move(to: CGPoint(x: -50, y: 32))
            route.addCurve(to: CGPoint(x: -18, y: 6), control1: CGPoint(x: -38, y: 16), control2: CGPoint(x: -28, y: 22))
            route.addCurve(to: CGPoint(x: 14, y: 8), control1: CGPoint(x: -8, y: -10), control2: CGPoint(x: 6, y: -8))
            route.addCurve(to: CGPoint(x: 40, y: -12), control1: CGPoint(x: 22, y: 24), control2: CGPoint(x: 32, y: 22))
            ctx.stroke(route, with: .color(theme.accent), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 4]))
            ctx.fill(Path(ellipseIn: CGRect(x: 35, y: -9.8, width: 10, height: 3.6)), with: .color(.black.opacity(0.10)))
            var pin = Path()
            pin.move(to: CGPoint(x: 40, y: -36))
            pin.addCurve(to: CGPoint(x: 30, y: -26), control1: CGPoint(x: 33, y: -36), control2: CGPoint(x: 30, y: -30))
            pin.addCurve(to: CGPoint(x: 40, y: -9), control1: CGPoint(x: 30, y: -18), control2: CGPoint(x: 40, y: -9))
            pin.addCurve(to: CGPoint(x: 50, y: -26), control1: CGPoint(x: 40, y: -9), control2: CGPoint(x: 50, y: -18))
            pin.addCurve(to: CGPoint(x: 40, y: -36), control1: CGPoint(x: 50, y: -30), control2: CGPoint(x: 47, y: -36))
            pin.closeSubpath()
            ctx.fill(pin, with: .color(theme.accent))
            ctx.fill(Path(ellipseIn: CGRect(x: 36.4, y: -29.6, width: 7.2, height: 7.2)), with: .color(.white))

            // 和纸胶带：半透明、两头撕得毛毛的，斜着压过地图上沿和左边那道折痕
            var t = ctx
            t.translateBy(x: -22, y: -42)
            t.rotate(by: .degrees(-7))
            let tape = Self.tapePath(width: 46, height: 14)
            t.drawLayer { l in
                l.addFilter(.shadow(color: .black.opacity(0.07), radius: 1, x: 0, y: 0.6))
                l.fill(tape, with: .color(theme.wash(0.55).opacity(0.72)))
            }
            t.drawLayer { l in
                l.clip(to: tape)
                var stripes = Path()
                var x: CGFloat = -30
                while x < 30 { stripes.move(to: CGPoint(x: x, y: -8)); stripes.addLine(to: CGPoint(x: x + 8, y: 8)); x += 6 }
                l.stroke(stripes, with: .color(.white.opacity(0.28)), lineWidth: 1.6)
            }
        }
        .aspectRatio(Self.box.aspect, contentMode: .fit)
    }

    /// 胶带：上下两条直边，左右两头是撕开的小锯齿
    static func tapePath(width w: CGFloat, height h: CGFloat) -> Path {
        let teeth: [CGFloat] = [0, 1.6, -0.4, 1.2, 0.2, 1.8, 0]
        var p = Path()
        p.move(to: CGPoint(x: -w / 2, y: -h / 2))
        p.addLine(to: CGPoint(x: w / 2, y: -h / 2))
        for (i, d) in teeth.enumerated() {
            p.addLine(to: CGPoint(x: w / 2 - d, y: -h / 2 + h * CGFloat(i) / CGFloat(teeth.count - 1)))
        }
        p.addLine(to: CGPoint(x: -w / 2, y: h / 2))
        for (i, d) in teeth.reversed().enumerated() {
            p.addLine(to: CGPoint(x: -w / 2 + d * 0.9 + (i % 2 == 0 ? 0.6 : 0), y: h / 2 - h * CGFloat(i) / CGFloat(teeth.count - 1)))
        }
        p.closeSubpath()
        return p
    }
}
