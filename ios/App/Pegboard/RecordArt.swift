import SwiftUI

// 档案袋索引卡角上压的四样小东西（10-04 Tilia：之前自用的 App那四张是花瓣上找的图，不能用；照着样子用代码画）。
// 配色只用主题色往白里调淡的几档，体积靠一层淡影子（跟洞洞板四件同一套规矩）。

/// 打开的心形吊坠盒：两半心并排，中间一颗合页，右边那半上面挂一截细链子
struct LocketArt: View {
    @EnvironmentObject private var theme: AppTheme
    var body: some View {
        Canvas { ctx, size in
            let k = size.height / 62
            ctx.scaleBy(x: k, y: k)
            // 链子：一串小椭圆往上
            for i in 0..<6 {
                let y = 2 + CGFloat(i) * 3.6
                ctx.stroke(Path(ellipseIn: CGRect(x: 46.5 + (i % 2 == 0 ? 0 : 0.6), y: y, width: 2.6, height: 3.6)),
                           with: .color(theme.wash(0.45)), lineWidth: 0.8)
            }
            func heart(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, tilt: Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: w * 0.42))
                p.addCurve(to: CGPoint(x: -w * 0.5, y: -w * 0.12), control1: CGPoint(x: -w * 0.18, y: w * 0.26), control2: CGPoint(x: -w * 0.5, y: w * 0.12))
                p.addCurve(to: CGPoint(x: 0, y: -w * 0.2), control1: CGPoint(x: -w * 0.5, y: -w * 0.42), control2: CGPoint(x: -w * 0.1, y: -w * 0.46))
                p.addCurve(to: CGPoint(x: w * 0.5, y: -w * 0.12), control1: CGPoint(x: w * 0.1, y: -w * 0.46), control2: CGPoint(x: w * 0.5, y: -w * 0.42))
                p.addCurve(to: CGPoint(x: 0, y: w * 0.42), control1: CGPoint(x: w * 0.5, y: w * 0.12), control2: CGPoint(x: w * 0.18, y: w * 0.26))
                p.closeSubpath()
                return p.applying(CGAffineTransform(rotationAngle: tilt * .pi / 180).concatenating(.init(translationX: cx, y: cy)))
            }
            for (cx, cy, tilt) in [(24.0, 42.0, -14.0), (48.0, 40.0, 8.0)] as [(CGFloat, CGFloat, Double)] {
                let outer = heart(cx, cy, 26, tilt: tilt)
                let inner = heart(cx, cy + 0.5, 19, tilt: tilt)
                ctx.fill(outer, with: .color(theme.wash(0.72)))
                ctx.fill(inner, with: .color(theme.wash(0.93)))
                ctx.stroke(outer, with: .color(theme.wash(0.38)), lineWidth: 1.1)
                ctx.stroke(inner, with: .color(theme.wash(0.55)), lineWidth: 0.7)
            }
            // 合页
            ctx.fill(Path(roundedRect: CGRect(x: 34.5, y: 46, width: 3.5, height: 7), cornerRadius: 1.5), with: .color(theme.wash(0.45)))
            // 一点高光
            ctx.fill(Path(ellipseIn: CGRect(x: 41, y: 32, width: 4, height: 2.2)), with: .color(.white.opacity(0.9)))
        }
        .aspectRatio(72 / 62, contentMode: .fit)
    }
}

/// 星星纽扣：圆角五角星，正中四个扣眼
struct StarButtonArt: View {
    @EnvironmentObject private var theme: AppTheme
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var star = Path()
            for i in 0..<10 {
                let a = -Double.pi / 2 + Double(i) * .pi / 5
                let r = (i % 2 == 0 ? 0.5 : 0.24) * s
                let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
            }
            star.closeSubpath()
            let round = star.strokedPath(StrokeStyle(lineWidth: s * 0.12, lineCap: .round, lineJoin: .round)).union(star)
            ctx.fill(round, with: .color(theme.wash(0.72)))
            ctx.stroke(round, with: .color(theme.wash(0.45)), lineWidth: 0.8)
            for (dx, dy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(CGFloat, CGFloat)] {
                let h = CGRect(x: c.x + dx * s * 0.07 - s * 0.045, y: c.y + 0.03 * s + dy * s * 0.07 - s * 0.045, width: s * 0.09, height: s * 0.09)
                ctx.fill(Path(ellipseIn: h), with: .color(theme.wash(0.96)))
                ctx.stroke(Path(ellipseIn: h), with: .color(theme.wash(0.45)), lineWidth: 0.7)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 老式转盘电话：底座、架在上面的听筒、正面一圈拨号孔、一截卷线
struct RotaryPhoneArt: View {
    @EnvironmentObject private var theme: AppTheme
    var body: some View {
        Canvas { ctx, size in
            let k = size.height / 58
            ctx.scaleBy(x: k, y: k)
            let line = theme.wash(0.42)
            // 底座（梯形，圆角）
            var base = Path()
            base.move(to: CGPoint(x: 14, y: 26)); base.addLine(to: CGPoint(x: 58, y: 26))
            base.addLine(to: CGPoint(x: 66, y: 54)); base.addLine(to: CGPoint(x: 6, y: 54)); base.closeSubpath()
            let body = base.strokedPath(StrokeStyle(lineWidth: 5, lineJoin: .round)).union(base)
            ctx.fill(body, with: .color(theme.wash(0.9)))
            ctx.stroke(body, with: .color(line), lineWidth: 0.9)
            // 听筒
            var h = Path()
            h.addRoundedRect(in: CGRect(x: 6, y: 13, width: 60, height: 8), cornerSize: CGSize(width: 4, height: 4))
            h.addRoundedRect(in: CGRect(x: 3, y: 9, width: 15, height: 12), cornerSize: CGSize(width: 6, height: 6))
            h.addRoundedRect(in: CGRect(x: 54, y: 9, width: 15, height: 12), cornerSize: CGSize(width: 6, height: 6))
            ctx.fill(h, with: .color(theme.wash(0.82)))
            ctx.stroke(h, with: .color(line), lineWidth: 0.9)
            // 拨号盘
            let dc = CGPoint(x: 36, y: 40), r: CGFloat = 11
            ctx.fill(Path(ellipseIn: CGRect(x: dc.x - r, y: dc.y - r, width: r * 2, height: r * 2)), with: .color(theme.wash(0.96)))
            ctx.stroke(Path(ellipseIn: CGRect(x: dc.x - r, y: dc.y - r, width: r * 2, height: r * 2)), with: .color(line), lineWidth: 0.9)
            for i in 0..<10 {
                let a = Double(i) / 10 * 1.7 * .pi + .pi * 0.25
                let p = CGPoint(x: dc.x + 7.6 * cos(a), y: dc.y + 7.6 * sin(a))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(line), lineWidth: 0.7)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: dc.x - 3.2, y: dc.y - 3.2, width: 6.4, height: 6.4)), with: .color(theme.accent))
            // 卷线
            var cord = Path()
            cord.move(to: CGPoint(x: 64, y: 48))
            for i in 0..<5 {
                let x = 66 + CGFloat(i) * 1.6
                cord.addCurve(to: CGPoint(x: x + 1.6, y: 44 - CGFloat(i) * 4), control1: CGPoint(x: x + 4, y: 47 - CGFloat(i) * 4), control2: CGPoint(x: x - 2, y: 45 - CGFloat(i) * 4))
            }
            ctx.stroke(cord, with: .color(line), lineWidth: 0.9)
        }
        .aspectRatio(74 / 58, contentMode: .fit)
    }
}

/// 点单小票（Guest Check）：上沿一排撕口，顶上一条主题色标题带，下面几行横线、一个小框
struct GuestCheckArt: View {
    @EnvironmentObject private var theme: AppTheme
    var body: some View {
        Canvas { ctx, size in
            let k = size.height / 66
            ctx.scaleBy(x: k, y: k)
            let w: CGFloat = 46, h: CGFloat = 64
            var paper = Path()
            paper.move(to: CGPoint(x: 0, y: 3))
            var x: CGFloat = 0
            while x < w {                          // 上沿撕口：一排小锯齿
                paper.addLine(to: CGPoint(x: x + 2, y: 0)); paper.addLine(to: CGPoint(x: min(w, x + 4), y: 3)); x += 4
            }
            paper.addLine(to: CGPoint(x: w, y: h)); paper.addLine(to: CGPoint(x: 0, y: h)); paper.closeSubpath()
            ctx.fill(paper, with: .color(Color(red: 0.995, green: 0.99, blue: 0.975)))
            ctx.stroke(paper, with: .color(theme.paperLine), lineWidth: 0.8)
            ctx.fill(Path(CGRect(x: 4, y: 7, width: w - 8, height: 9)), with: .color(theme.wash(0.62)))
            ctx.draw(Text("GUEST CHECK").font(.system(size: 5.2, weight: .bold, design: .serif)).foregroundColor(.white),
                     at: CGPoint(x: w / 2, y: 11.5))
            for i in 0..<6 {
                let y = 24 + CGFloat(i) * 6.5
                var l = Path(); l.move(to: CGPoint(x: 5, y: y)); l.addLine(to: CGPoint(x: w - 5, y: y))
                ctx.stroke(l, with: .color(theme.wash(0.72)), lineWidth: 0.6)
            }
            var col = Path(); col.move(to: CGPoint(x: w - 14, y: 20)); col.addLine(to: CGPoint(x: w - 14, y: 58))
            ctx.stroke(col, with: .color(theme.wash(0.72)), lineWidth: 0.6)
            ctx.stroke(Path(CGRect(x: w - 14, y: 56, width: 9, height: 5)), with: .color(theme.wash(0.5)), lineWidth: 0.6)
        }
        .aspectRatio(46 / 66, contentMode: .fit)
    }
}
