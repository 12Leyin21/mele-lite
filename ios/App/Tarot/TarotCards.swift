import SwiftUI

// MARK: - 牌面、牌背、翻牌、扇形几何（移植自之前自用的 App TarotRoomView.swift，我们自己写的）
//
// 牌面：1909 韦特公版扫描（Assets.xcassets/Tarot/tarot_<key>，出处见 THIRD_PARTY.md）。
// 牌背：之前自用的 App那张星空图（Tilia 10-03 定 Mele 也用），边框照之前自用的 App：偏蓝的冷白、六成透。

struct TarotCardFace: View {
    let card: TarotCardDTO
    var width: CGFloat = 96

    private var height: CGFloat { width * 1.62 }

    var body: some View {
        Image("tarot_\(card.card)")
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: width * 0.09, style: .continuous))
            .rotationEffect(.degrees(card.reversed ? 180 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: width * 0.09, style: .continuous)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
    }
}

struct TarotCardBack: View {
    var width: CGFloat = 56
    var glow = false
    /// 收成一摞的时候 78 张的阴影全落在同一处会叠成一团黑——摞里只给最上面几张
    var shadowed = true

    var body: some View {
        Image("tarot_back")
            .resizable()
            .scaledToFill()
            .frame(width: width, height: width * 1.62)
            .clipShape(RoundedRectangle(cornerRadius: width * 0.09, style: .continuous))
            .overlay {
                // Tilia（之前自用的 App 09-04）：纯白晃眼、暖白不喜欢 → 偏蓝的冷白、六成透
                RoundedRectangle(cornerRadius: width * 0.09, style: .continuous)
                    .stroke(glow ? Color.white.opacity(0.95) : Color(red: 0.84, green: 0.89, blue: 1.0).opacity(0.6),
                            lineWidth: glow ? 1.8 : 1.0)
            }
            // 往左下投一道软阴影，压在下面那张牌上——叠起来才有厚度
            .shadow(color: .black.opacity(shadowed ? (glow ? 0.5 : 0.42) : 0), radius: glow ? 9 : 4,
                    x: glow ? 0 : -4, y: glow ? 5 : 2)
    }
}

/// 翻牌：0° 是背面，转到 90° 换成正面（正面预先翻了 180°，转到位正好朝前）
struct TarotFlipCard: View, Animatable {
    var angle: Double
    let card: TarotCardDTO
    let width: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                TarotCardBack(width: width, glow: false)
            } else {
                TarotCardFace(card: card, width: width)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
    }
}

/// 牌位示意小图：按 layout 摆小圆角矩形
struct SpreadDiagram: View {
    let spread: TarotSpreadDTO
    let style: TarotStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<spread.count, id: \.self) { index in
                    let p = spread.point(index)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(style.diagramStroke, lineWidth: 1.1)
                        .background(RoundedRectangle(cornerRadius: 2.5).fill(style.diagramFill))
                        .frame(width: 14, height: 21)
                        .rotationEffect(.degrees(spread.key == "celtic" && index == 1 ? 90 : 0))
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                }
            }
        }
    }
}

/// 扇形的几何（之前自用的 App 09-04 第四版）：同一个圆心两排，上排半径大所以更宽，下排压在上排下半截上。
struct FanGeometry {
    static let cardWidth: CGFloat = 56
    static var cardHeight: CGFloat { cardWidth * 1.62 }
    static let lift: CGFloat = 26
    /// 两排半径差：下排只搭着上排最底下那一截
    static var rowGap: CGFloat { cardHeight * 0.82 }

    let size: CGSize
    let count: Int

    /// 上排多、下排少（78 张时 42 / 36）
    var topCount: Int { count <= 1 ? count : Int((Double(count) * 42 / 78).rounded()) }
    var bottomCount: Int { count - topCount }
    func row(of k: Int) -> Int { k < topCount ? 0 : 1 }
    func rowCount(_ row: Int) -> Int { row == 0 ? topCount : bottomCount }

    /// 半径只有区域宽的一半多一点：圆心离牌很近，牌尾往一个点收
    var bottomRadius: CGFloat { max(size.width, 300) * 0.56 }
    var topRadius: CGFloat { bottomRadius + Self.rowGap }
    func radius(row: Int) -> CGFloat { row == 0 ? topRadius : bottomRadius }

    /// 张角按「两端那张牌整张留在区域里」倒推；下排再往里收一点，扇形才有收口
    func span(row: Int) -> Double {
        let chord = max(size.width - Self.cardWidth * 1.3 - (row == 0 ? 0 : 60), 120)
        return 2 * Double(asin(min(chord / (2 * radius(row: row)), 0.92))) * 180 / .pi
    }
    func sagitta(row: Int) -> CGFloat {
        radius(row: row) * (1 - cos(CGFloat(span(row: row) / 2 * .pi / 180)))
    }

    var totalHeight: CGFloat { sagitta(row: 1) + Self.rowGap + Self.cardHeight }
    var edgeY: CGFloat { (size.height - totalHeight) / 2 + sagitta(row: 1) + Self.rowGap + Self.cardHeight / 2 }
    var circleCenter: CGPoint { CGPoint(x: size.width / 2, y: edgeY - sagitta(row: 1) + bottomRadius) }
    /// 收成一叠时的中心
    var stackY: CGFloat { edgeY - sagitta(row: 1) - Self.rowGap / 2 }

    /// 叠放次序：每排左到右一路压过去；下排整体压在上排上面
    func stackOrder(k: Int) -> Double {
        let r = row(of: k)
        return Double(r) * 100 + Double(r == 0 ? k : k - topCount)
    }

    func angle(k: Int) -> Double {
        let r = row(of: k)
        let n = rowCount(r)
        let i = r == 0 ? k : k - topCount
        guard n > 1 else { return 0 }
        let sp = span(row: r)
        return -sp / 2 + sp * Double(i) / Double(n - 1)
    }

    func center(k: Int) -> CGPoint {
        let rad = CGFloat(angle(k: k) * .pi / 180)
        let R = radius(row: row(of: k))
        return CGPoint(x: circleCenter.x + R * sin(rad), y: circleCenter.y - R * cos(rad))
    }

    /// 触点最近的那张：先按离圆心的距离分排，再按角度找；点得离牌太远就当没碰到
    func nearest(to p: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let dx = p.x - circleCenter.x, dy = circleCenter.y - p.y
        let dist = hypot(dx, dy)
        let r = (bottomCount > 0 && abs(dist - bottomRadius) <= abs(dist - topRadius)) ? 1 : 0
        guard abs(dist - radius(row: r)) < Self.cardHeight * 0.75 else { return nil }
        let n = rowCount(r)
        guard n > 0 else { return nil }
        let phi = atan2(dx, dy) * 180 / .pi
        guard n > 1 else { return r == 0 ? 0 : topCount }
        let sp = span(row: r)
        let step = sp / Double(n - 1)
        let i = min(max(Int(((phi + sp / 2) / step).rounded()), 0), n - 1)
        return r == 0 ? i : topCount + i
    }

    /// 触点是不是落在这张（已经凸起来的）牌身上：换到牌自己的坐标系里比
    func hits(point p: CGPoint, cardAt pose: (center: CGPoint, rotation: Double)) -> Bool {
        let rad = CGFloat(-pose.rotation * .pi / 180)
        let dx = p.x - pose.center.x, dy = p.y - pose.center.y
        let lx = dx * cos(rad) - dy * sin(rad)
        let ly = dx * sin(rad) + dy * cos(rad)
        return abs(lx) <= Self.cardWidth / 2 + 6 && abs(ly) <= Self.cardHeight / 2 + 6
    }
}
