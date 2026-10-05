import PhotosUI
import SwiftUI

// MARK: - 照片 / 纪念日小组件（10-03 Tilia）
//
// 照片：导入一张，铺满整张卡，没有边框。
// 纪念日：自己写标题（「和Quercus在一起第」）、选日子，可以置顶一个。
//   小号 = 置顶那个；中号 = 左边大大的置顶、右边小字列其他的（每个日期旁一道竖杠）；大号 = 全部，置顶的在最上面。
// 都存本机。

struct Anniversary: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var pinned = false

    /// 过去的日子：第几天（当天算第 1 天）；还没到的：还有几天
    var dayCount: Int {
        let cal = Calendar.current
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return d >= 0 ? d + 1 : -d
    }
    var isFuture: Bool { Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: Date()) }
    var unit: String { isFuture ? String(localized: "天后") : String(localized: "天") }
}

@MainActor
final class AnniversaryStore: ObservableObject {
    static let shared = AnniversaryStore()
    private static let key = "anniversaries"

    @Published var items: [Anniversary] {
        didSet { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.key) } }
    }

    init() {
        items = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Anniversary].self, from: $0) } ?? []
    }

    /// 置顶的在前，其余按日子先后
    var ordered: [Anniversary] {
        items.filter(\.pinned) + items.filter { !$0.pinned }.sorted { $0.date < $1.date }
    }
    var pinned: Anniversary? { items.first(where: \.pinned) ?? ordered.first }

    func pin(_ id: UUID) {
        for i in items.indices { items[i].pinned = items[i].id == id ? !items[i].pinned : false }
    }
}

// MARK: 纪念日卡

struct AnniversaryCard: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var store = AnniversaryStore.shared
    let size: WidgetSize
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Group {
                if let top = store.pinned {
                    switch size {
                    case .small: big(top).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    case .medium:
                        // 照之前自用的 App首页「us · Day 90」那张
                        usBlock(top).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    case .large:
                        // 上面是置顶那张的样子，下面照之前自用的 App anniversary 那一格格：竖杠 + 名字 + 日子 + 大数字
                        VStack(alignment: .leading, spacing: 14) {
                            usBlock(top)
                            Rectangle().fill(Color.white.opacity(0.5)).frame(height: 1)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(Array(store.ordered.filter { $0.id != top.id }.prefix(4))) { countColumn($0) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("纪念日").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        Spacer(minLength: 0)
                        Text("点一下记第一个日子").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) {
            AnniversaryEditor().presentationDetents([.medium, .large]).environment(\.colorScheme, .light)
        }
    }

    /// 大的那个：标题、大数字、日期
    private func big(_ a: Anniversary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(a.title).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(a.dayCount)")
                    .font(Typo.accent(size == .large ? Typo.Size.largeTitle * 1.6 : Typo.Size.largeTitle))
                    .foregroundStyle(theme.ink)
                Text(a.unit).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
            }
            Spacer(minLength: 0)
            Text(a.date, format: .dateTime.year().month().day())
                .font(Typo.number(Typo.Size.caption, .regular)).foregroundStyle(theme.inkFaint)
        }
        .frame(width: size == .medium ? 128 : nil, alignment: .leading)
    }

    /// 「us · Day 90」：左上小标题、右上一颗心，中间大大的 Day N（主题色斜体），底下一行日子
    private func usBlock(_ a: Anniversary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(a.title).font(Typo.accent(Typo.Size.body, .regular)).foregroundStyle(theme.inkDim).lineLimit(1)
                Spacer()
                Image(systemName: "heart.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.75))
            }
            Text(a.isFuture ? String(localized: "还有 \(a.dayCount) 天") : "Day \(a.dayCount)")
                .font(Typo.accent(size == .large ? 52 : 46).italic())
                .foregroundStyle(theme.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(a.isFuture ? a.date.formatted(.dateTime.year().month().day())
                            : String(localized: "从 \(a.date.formatted(.dateTime.year().month().day())) 到每一天"))
                .font(Typo.accent(Typo.Size.callout, .regular))
                .foregroundStyle(theme.inkDim)
        }
    }

    /// anniversary 那一格：主题色竖杠 + 名字 + 日子（斜体小字）+ 大数字
    private func countColumn(_ a: Anniversary) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(Typo.accent(Typo.Size.caption, .regular)).foregroundStyle(theme.ink).lineLimit(1)
                Text(a.date, format: .dateTime.month(.abbreviated).day())
                    .font(Typo.accent(Typo.Size.caption).italic()).foregroundStyle(theme.inkFaint)
                Text(a.isFuture ? "\(a.dayCount)" : "Day \(a.dayCount)")
                    .font(Typo.accent(24).italic()).foregroundStyle(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 小字列表：每个日期旁一道主题色竖杠
    private func list<S: Sequence>(_ items: S) -> some View where S.Element == Anniversary {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items)) { a in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(theme.accent).frame(width: 2.5, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(a.dayCount) \(a.unit)").font(Typo.number(Typo.Size.caption, .semibold)).foregroundStyle(theme.ink)
                            Text(a.date, format: .dateTime.year().month().day())
                                .font(Typo.number(Typo.Size.caption, .regular)).foregroundStyle(theme.inkFaint)
                        }
                    }
                }
            }
        }
    }
}

/// 点纪念日卡打开：加 / 改 / 删 / 置顶
struct AnniversaryEditor: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AnniversaryStore.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach($store.items) { $a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("比如：和小满在一起第", text: $a.title)
                                .font(Typo.sans(Typo.Size.body))
                            Button { store.pin(a.id) } label: {
                                Image(systemName: a.pinned ? "pin.fill" : "pin")
                                    .foregroundStyle(a.pinned ? theme.accent : theme.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                        DatePicker("日子", selection: $a.date, displayedComponents: .date)
                            .font(Typo.sans(Typo.Size.callout))
                            .tint(theme.accent)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { store.items.remove(atOffsets: $0) }
                Button {
                    store.items.append(Anniversary(title: "", date: Date(), pinned: store.items.isEmpty))
                } label: {
                    Label("记一个日子", systemImage: "plus").font(Typo.sans(Typo.Size.body))
                }
                .tint(theme.accent)
            }
            .navigationTitle("纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.tint(theme.accent) } }
        }
    }
}

// MARK: 照片卡

enum WidgetPhotos {
    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ data: Data) -> String? {
        guard let img = UIImage(data: data), let jpg = img.scaledDown(maxSide: 1600).jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        return (try? jpg.write(to: dir.appendingPathComponent(name))) != nil ? name : nil
    }

    static func image(_ name: String?) -> UIImage? {
        name.flatMap { UIImage(contentsOfFile: dir.appendingPathComponent($0).path) }
    }
}

struct PhotoCard: View {
    @EnvironmentObject private var theme: AppTheme
    let photo: String?
    let onPick: (String) -> Void
    @State private var picking = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = WidgetPhotos.image(photo) {
                    // 图只铺满这一格、多出来的剪掉（以前图的大小会把小组件撑长）
                    Color.clear
                        .overlay { Image(uiImage: img).resizable().scaledToFill() }
                        .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                } else {
                    Button { picking = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "photo").font(Typo.icon(20)).foregroundStyle(theme.accent)
                            Text("选一张照片").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .photoImport(isPresented: $picking, aspect: geo.size.width / max(1, geo.size.height)) { img in
                if let data = img.jpegData(compressionQuality: 0.88), let name = WidgetPhotos.save(data) { onPick(name) }
            }
        }
    }
}

/// 拍立得（10-04 Tilia）：白边，左右上一样窄、底下宽一截；照片只在中间的窗里
struct PolaroidCard: View {
    @EnvironmentObject private var theme: AppTheme
    let photo: String?
    let onPick: (String) -> Void
    @State private var picking = false

    /// 白边多宽（按短边算）
    static func margins(_ size: CGSize) -> (side: CGFloat, bottom: CGFloat) {
        let m = min(size.width, size.height) * 0.065
        return (m, m * 3.4)
    }
    /// 中间那个窗的宽高比
    static let windowAspect: (CGSize) -> CGFloat = { size in
        let (m, b) = margins(size)
        return (size.width - m * 2) / max(1, size.height - m - b)
    }

    var body: some View {
        GeometryReader { geo in
            let (m, b) = Self.margins(geo.size)
            let window = CGSize(width: geo.size.width - m * 2, height: geo.size.height - m - b)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hue: theme.hue / 360, saturation: 0.015, brightness: 0.995))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(theme.paperLineSoft, lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.10), radius: 1.2, y: 1)
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 2, y: 6)
                Group {
                    if let img = WidgetPhotos.image(photo) {
                        Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }
                    } else {
                        Button { picking = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "photo").font(Typo.icon(18)).foregroundStyle(theme.accent)
                                Text("选一张照片").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.wash(0.9))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: window.width, height: window.height)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.black.opacity(0.05), lineWidth: 0.5))
                .padding(.top, m)
            }
            .photoImport(isPresented: $picking, aspect: Self.windowAspect(geo.size)) { img in
                if let data = img.jpegData(compressionQuality: 0.88), let name = WidgetPhotos.save(data) { onPick(name) }
            }
        }
    }
}

/// 编辑状态下照片卡角上的「换照片」（铺满整张卡量出它的宽高比，按钮放左下角）
struct ChangePhotoButton: View {
    @EnvironmentObject private var theme: AppTheme
    /// 按整张卡的大小算要框成什么比例（拍立得只框中间那个窗）
    var aspect: (CGSize) -> CGFloat = { $0.width / max(1, $0.height) }
    let onPick: (String) -> Void
    @State private var picking = false

    var body: some View {
        GeometryReader { geo in
            Button { picking = true } label: {
                Image(systemName: "photo")
                    .font(Typo.icon(12, .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .photoImport(isPresented: $picking, aspect: aspect(geo.size)) { img in
                if let data = img.jpegData(compressionQuality: 0.88), let name = WidgetPhotos.save(data) { onPick(name) }
            }
        }
    }
}
