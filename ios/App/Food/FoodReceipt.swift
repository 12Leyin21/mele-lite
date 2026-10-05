import SwiftUI

// MARK: - 记一餐的刷卡机小票 + 卡包（10-04 Tilia）
//
// 「记一餐」右上角的完成键是一台小刷卡机；点了，后面整页模糊，机头的出纸口往下吐一张小票：
// 一行一样「食物 — 热量」、总热量、运动；有照片的话用一枚主题色回形针别在小票尾巴的右下角。
// 小票纸是暖白。点空白处收起小票、回到记一餐；点「收进卡包」，小票飞进 Food Diary 右下角的卡包。
// 卡包里一张张叠着，左右滑翻看。存本机（收的那一刻的样子，之后改记录不影响已经收起来的小票）。

struct FoodReceiptLine: Codable, Hashable {
    var name: String
    var kcal: String
}

struct FoodReceiptData: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: String
    var printedAt = Date()
    var foods: [FoodReceiptLine]
    var total: Int
    var moves: [FoodReceiptLine]
    var photo: String

    init(date: String, foods: [FoodReceiptLine], total: Int, moves: [FoodReceiptLine], photo: String) {
        self.date = date; self.foods = foods; self.total = total; self.moves = moves; self.photo = photo
    }

    init(day: FoodDay) {
        date = day.date
        foods = day.entries.filter { $0.meal != FoodMeal.exercise.rawValue }.map {
            FoodReceiptLine(name: $0.text, kcal: $0.pending ? String(localized: "估中") : $0.kcal.map { "\(Int($0.rounded()))" } ?? "—")
        }
        total = day.summary.kcal
        moves = day.entries.filter { $0.meal == FoodMeal.exercise.rawValue }.map {
            FoodReceiptLine(name: String(localized: "运动 · \($0.text)"), kcal: $0.kcal.map { "−\(Int($0.rounded()))" } ?? "…")
        }
        photo = day.cover ?? day.entries.first(where: { !$0.photo.isEmpty })?.photo ?? ""
    }
}

/// 卡包：收起来的小票，新的在前；同一天再收一次就换成新的那张
@MainActor
final class ReceiptBook: ObservableObject {
    static let shared = ReceiptBook()
    private static let key = "foodReceiptBook"
    @Published private(set) var receipts: [FoodReceiptData] = []

    init() {
        receipts = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([FoodReceiptData].self, from: $0) } ?? []
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seedReceipts") && receipts.isEmpty {   // 模拟器自测：塞三张假小票
            receipts = (1...3).map { i in
                var r = FoodReceiptData(date: "2026-10-0\(i)", foods: [.init(name: "燕麦牛奶", kcal: "320"), .init(name: "鸡胸肉沙拉", kcal: "410")],
                                        total: 730, moves: [.init(name: "运动 · 散步", kcal: "−120")], photo: "")
                r.id = UUID()
                return r
            }
        }
        #endif
    }

    func collect(_ r: FoodReceiptData) {
        receipts.removeAll { $0.date == r.date }
        receipts.insert(r, at: 0)
        save()
    }

    func remove(_ r: FoodReceiptData) {
        receipts.removeAll { $0.id == r.id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(receipts) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// 完成键：一台小刷卡机
struct EftposIcon: View {
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(theme.accent, lineWidth: 1.6)
                .frame(width: 16, height: 21)
            RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.opacity(0.35))
                .frame(width: 10, height: 5).padding(.top, 3.5)
            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 2.2) { ForEach(0..<3, id: \.self) { _ in Circle().fill(theme.accent).frame(width: 2.2, height: 2.2) } }
                }
            }
            .padding(.top, 11)
        }
        .frame(width: 24, height: 24)
    }
}

struct FoodReceiptOverlay: View {
    @EnvironmentObject private var theme: AppTheme
    let receipt: FoodReceiptData
    let onClose: () -> Void
    @State private var printed: CGFloat = 0
    @State private var flying = false
    @State private var cut: CGFloat = 0            // 裁纸刀划到哪了（0 → 1）
    @State private var cutting = false
    @State private var detached = false            // 剪下来了：往下掉一点、歪一下

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    EftposHead().frame(width: 300, height: 58).zIndex(1)
                        .overlay(alignment: .bottom) {
                            if cutting { Cutter(progress: cut).frame(width: 256, height: 18).offset(y: 9) }
                        }
                        .zIndex(2)
                    FoodReceiptPaper(receipt: receipt)
                        .frame(width: 256)
                        .contentShape(Rectangle())
                        .onTapGesture {}                      // 点小票本身不收
                        .mask(alignment: .top) {
                            GeometryReader { g in Rectangle().frame(height: g.size.height * printed) }
                                .padding(.horizontal, -80)
                                .padding(.bottom, -60)          // 别在尾巴上的照片探出纸外，别被裁掉
                        }
                        .offset(y: -16)
                        .rotationEffect(.degrees(detached ? -3 : 0), anchor: .top)
                        .offset(y: detached ? 22 : 0)
                        .scaleEffect(flying ? 0.15 : 1, anchor: .bottomTrailing)
                        .offset(x: flying ? 120 : 0, y: flying ? 420 : 0)
                        .opacity(flying ? 0 : 1)
                    Button {
                        collect()
                    } label: {
                        Label("收进卡包", systemImage: "wallet.pass")
                            .font(Typo.sans(Typo.Size.callout, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 46)
                    .opacity(printed == 1 && !cutting ? 1 : 0)
                }
                .padding(.top, 70)
                .padding(.bottom, 60)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .top) { h, _ in h }
            }
            .scrollIndicators(.hidden)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
        }
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.easeOut(duration: 1.5)) { printed = 1 } }
    }

    /// 收进卡包：裁纸刀从左划到右 → 小票掉下来一点 → 飞进卡包
    private func collect() {
        ReceiptBook.shared.collect(receipt)
        cutting = true
        withAnimation(.easeInOut(duration: 0.5)) { cut = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { detached = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            withAnimation(.easeIn(duration: 0.45)) { flying = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45, execute: onClose)
    }
}

/// 裁纸刀：一条细轨上滑过去的主题色小把手，刀尖朝下；身后留一道虚线切痕
private struct Cutter: View {
    @EnvironmentObject private var theme: AppTheme
    let progress: CGFloat

    var body: some View {
        GeometryReader { g in
            let x = g.size.width * progress
            ZStack(alignment: .leading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: g.size.height / 2))
                    p.addLine(to: CGPoint(x: x, y: g.size.height / 2))
                }
                .stroke(theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                VStack(spacing: 0) {
                    Capsule().fill(theme.accent).frame(width: 26, height: 10)
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                    Triangle().fill(Color.white).frame(width: 8, height: 6)
                        .overlay(Triangle().stroke(theme.accent.opacity(0.5), lineWidth: 0.6))
                }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .offset(x: x - 13)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 刷卡机只画出纸那一截：机身、一颗小灯、出纸缝
private struct EftposHead: View {
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.97, green: 0.965, blue: 0.95))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.accent.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            HStack {
                Circle().fill(theme.accent).frame(width: 7, height: 7)
                Spacer()
                Capsule().fill(Color.white).frame(width: 44, height: 8)
                    .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 0.6))
            }
            .padding(.horizontal, 26)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)
            Capsule().fill(Color(white: 0.42).opacity(0.75))
                .frame(width: 236, height: 8)
                .padding(.bottom, 12)
        }
    }
}

struct FoodReceiptPaper: View {
    @EnvironmentObject private var theme: AppTheme
    let receipt: FoodReceiptData
    private let ink = Color(white: 0.18)

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                Text("MELE · 今日小票").font(.system(size: 15, weight: .bold, design: .monospaced))
                Text(dateLine).font(.system(size: 11.5, design: .monospaced)).opacity(0.75)
            }
            dashes
            if receipt.foods.isEmpty {
                Text("这天还没吃东西").font(.system(size: 12, design: .monospaced)).opacity(0.6).padding(.vertical, 4)
            }
            ForEach(Array(receipt.foods.enumerated()), id: \.offset) { _, l in row(l.name, l.kcal) }
            dashes
            HStack {
                Text("总热量")
                Spacer()
                Text("\(receipt.total)")
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            ForEach(Array(receipt.moves.enumerated()), id: \.offset) { _, l in row(l.name, l.kcal) }
            dashes
            Text("今天也好好吃饭了").font(.system(size: 11, design: .monospaced)).opacity(0.75)
            barcode.padding(.top, 2)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(Color(red: 0.99, green: 0.98, blue: 0.955))
        .mask(ZigzagEdges())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .overlay(alignment: .bottomTrailing) {
            if !receipt.photo.isEmpty { pinnedPhoto }
        }
    }

    /// 照片别在小票尾巴的右下角（Tilia 10-04 用红笔画的位置）：大半压在纸上，往右下探出去一点，
    /// 斜着；回形针从照片上沿夹住
    private var pinnedPhoto: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                AuthImageView(urlPath: receipt.photo)
                    .frame(width: 78, height: 78)
                    .clipped()
                Color.white.frame(width: 78, height: 12)
            }
            .padding(5)
            .background(Color.white)
            .frame(width: 88, height: 100)
            .fixedSize()
            .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
            PaperClip()
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 34)
                .offset(x: 10, y: -12)            // 夹在照片上沿正中偏右（Tilia 10-04 用红笔圈的位置）
        }
        .rotationEffect(.degrees(20))
        .offset(x: 22, y: 14)
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let d = f.date(from: receipt.date) ?? receipt.printedAt
        return d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).weekday(.abbreviated)) + " " + receipt.printedAt.formatted(.dateTime.hour().minute())
    }

    private var dashes: some View {
        Text(String(repeating: "- ", count: 18)).font(.system(size: 10, design: .monospaced)).lineLimit(1).opacity(0.5)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).lineLimit(2)
            Spacer(minLength: 8)
            Text(v)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var barcode: some View {
        let seed = receipt.date.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }
        return HStack(spacing: 1.5) {
            ForEach(0..<34, id: \.self) { i in
                Rectangle().frame(width: [1, 1.5, 2.5, 1][abs(seed >> (i % 16) ^ i) % 4], height: 30)
            }
        }
    }
}

/// 回形针：一根线绕两圈的样子（竖着）
struct PaperClip: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.25, y: h * 0.62))
        p.addLine(to: CGPoint(x: w * 0.25, y: h * 0.2))
        p.addArc(center: CGPoint(x: w * 0.5, y: h * 0.2), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.82))
        p.addArc(center: CGPoint(x: w * 0.5, y: h * 0.82), radius: w * 0.25, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: w * 0.25, y: h * 0.12))
        p.addArc(center: CGPoint(x: w * 0.5, y: h * 0.12), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.6))
        return p
    }
}

// MARK: - 卡包：收起来的小票叠在一起，左右滑翻

struct ReceiptBookView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var book = ReceiptBook.shared
    @State private var current: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if book.receipts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wallet.pass").font(.system(size: 34)).foregroundStyle(theme.accent)
                        Text("卡包还是空的").font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                        Text("记完一天，点右上角的刷卡机打一张小票，再收进来").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(book.receipts) { r in
                                ZStack {
                                    // 后面叠着的两张（只露个边）
                                    ForEach([2, 1], id: \.self) { k in
                                        Color(red: 0.99, green: 0.98, blue: 0.955)
                                            .frame(width: 256, height: 300)
                                            .mask(ZigzagEdges())
                                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                                            .rotationEffect(.degrees(Double(k) * (k == 1 ? -2.5 : 3)))
                                            .offset(x: CGFloat(k) * 5, y: CGFloat(k) * -6)
                                    }
                                    FoodReceiptPaper(receipt: r).frame(width: 256)
                                        .contextMenu {
                                            Button(role: .destructive) { withAnimation { book.remove(r) } } label: { Label("从卡包里拿掉", systemImage: "trash") }
                                        }
                                }
                                .padding(.vertical, 40)
                                .containerRelativeFrame(.horizontal)
                                .scrollTransition(axis: .horizontal) { v, phase in
                                    v.rotationEffect(.degrees(phase.value * 6)).scaleEffect(1 - abs(phase.value) * 0.08).opacity(1 - abs(phase.value) * 0.4)
                                }
                                .id(r.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $current)
                }
            }
            .background(AppBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关上") { dismiss() }.tint(theme.accent) } }
        }
        .environment(\.colorScheme, .light)
    }

    private var title: String {
        guard !book.receipts.isEmpty else { return String(localized: "卡包") }
        let i = (book.receipts.firstIndex { $0.id == current } ?? 0) + 1
        return String(localized: "卡包 · \(i) / \(book.receipts.count)")
    }
}
