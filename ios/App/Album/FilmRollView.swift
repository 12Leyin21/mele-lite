import LocalAuthentication
import SwiftUI

// MARK: - 相册 · 胶卷看法（10-02 Tilia定的方向 2，第三版）
//
// 顶上：‹ · 年份 · 切宫格；三本（全部 / 收藏 / 隐私，隐私要 Face ID，照之前自用的 App）是浮在底部的一条胶囊。
// 一页摆这一年的十二个月，每个月一小打胶片叠着（月份是粘在第一张上沿的书页小标签），没照片的月份只留一个空框。
// 点一个月：那一打飞到屏幕中间、变大，后面的页面糊上一层磨砂（之前自用的 App相册点开照片那种），然后横向摊开，左右滑看这个月。
// 点空白处、✕ 或者标签收回去。片基是白纱 + 主题色半透明，齿孔是镂空的，透出后面。
// 真数据从 AlbumStore 来（-albumPreview 自测时用画出来的假照片）。点一格开看图页（AlbumViewer，移植自之前自用的 App），长按收藏 / 隐私 / 删。

extension Notification.Name {
    static let lumiOpenAlbum = Notification.Name("LumiOpenAlbum")
}

/// 胶片上的一格：真相册里是一张 AlbumPhotoDTO（图从服务器拉小图）；样子预览里是画出来的 UIImage
struct FilmFrame: Identifiable {
    let id: Int
    let date: Date
    var image: UIImage? = nil
    var photo: AlbumPhotoDTO? = nil
    var starred = false
    var secret = false

    init(id: Int, date: Date, image: UIImage, starred: Bool = false, secret: Bool = false) {
        self.id = id; self.date = date; self.image = image; self.starred = starred; self.secret = secret
    }

    init(_ p: AlbumPhotoDTO) {
        id = p.id; date = p.takenAt; photo = p; starred = p.starred; secret = p.secret
    }

    var aspect: CGFloat? { image.map { $0.size.width / max($0.size.height, 1) } }

    /// 裁满的图：胶片、宫格用小图；看图页用原图（full）
    @ViewBuilder
    func picture(full: Bool = false) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let photo {
            AuthImageView(urlPath: full ? photo.url : photo.thumb)
        } else {
            Color.clear
        }
    }
}

struct FilmRoll: Identifiable {
    let month: Date
    let frames: [FilmFrame]
    var id: Date { month }
}

enum AlbumBook: CaseIterable {
    case all, starred, secret
    var label: String {
        switch self {
        case .all: String(localized: "全部")
        case .starred: String(localized: "收藏")
        case .secret: String(localized: "隐私")
        }
    }
    var icon: String {
        switch self {
        case .all: "square.stack"
        case .starred: "star.fill"
        case .secret: "lock.fill"
        }
    }
}

/// 胶片的尺寸，一套数按比例缩（月历上的小打 / 点开的大打）。标签的字不跟着缩
struct FilmMetrics {
    let k: CGFloat
    var frameW: CGFloat { 150 * k }
    var frameH: CGFloat { 100 * k }
    var pad: CGFloat { 8 * k }
    var rail: CGFloat { 20 * k }
    var cellW: CGFloat { frameW + pad * 2 }
    var cellH: CGFloat { frameH + rail * 2 }
    static let big = FilmMetrics(k: 1.55)       // 点开那一打（10-02 Tilia：再大一点，一格占大半个屏幕）
    static let small = FilmMetrics(k: 0.5)
}

struct FilmRollView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    /// 样子预览用的假照片；nil = 真相册
    var demo: [FilmFrame]? = nil
    /// 联系人的名字（看图页写「xx 的观后感」）
    var names: [UUID: String] = [:]
    @StateObject private var store = AlbumStore()
    @State private var viewer: AlbumViewerJob?
    @State private var adding = false
    @State private var confirmDelete: AlbumPhotoDTO?

    private var live: Bool { demo == nil }
    private var frames: [FilmFrame] { demo ?? store.photos(book).map(FilmFrame.init) }

    @State private var book: AlbumBook = .all
    @State private var unlocked = false
    @State private var grid = false
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var lifted: Lifted?
    @State private var liftedOpen = false
    @State private var landed = false
    /// 摊开那条横着挪到哪了（自己管的滑动，见 liftedLayer）
    @State private var stripX: CGFloat = 0
    @State private var stripDrag: CGFloat = 0
    /// 摊开那一行在屏幕上的位置（点哪一格按它算）
    @State private var stripRow: CGRect = .zero

    struct Lifted { let roll: FilmRoll; let from: CGRect }

    private var cal: Calendar { Calendar.current }

    private var shown: [FilmFrame] {
        if live { return book == .secret && !unlocked ? [] : frames }
        switch book {
        case .all: return frames.filter { !$0.secret }
        case .starred: return frames.filter { $0.starred && !$0.secret }
        case .secret: return unlocked ? frames.filter(\.secret) : []
        }
    }

    private var years: [Int] {
        Set(frames.map { cal.component(.year, from: $0.date) } + [cal.component(.year, from: Date())]).sorted()
    }

    private func roll(_ month: Int) -> FilmRoll {
        let start = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let list = shown.filter { cal.isDate($0.date, equalTo: start, toGranularity: .month) }.sorted { $0.date < $1.date }
        return FilmRoll(month: start, frames: list)
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 14) {
                topBar
                if book == .secret && !unlocked {
                    lockedPane
                } else if grid {
                    gridView
                } else {
                    monthsView
                }
            }
            .padding(.top, 8)
            VStack {
                Spacer()
                bookBar
            }
            .padding(.bottom, 10)
            if let lifted { liftedLayer(lifted) }
        }
        .coordinateSpace(name: "album")
        .environment(\.colorScheme, .light)
        .task(id: book) {
            guard live, book != .secret || unlocked else { return }
            await store.load(book, api: session.api)
            if let y = store.photos(book).first.map({ cal.component(.year, from: $0.takenAt) }), !years.contains(year) { year = y }
        }
        .fullScreenCover(item: $viewer) { job in
            AlbumViewer(frames: job.frames, start: job.start, name: companionName)
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $adding) { AlbumAddSheet(store: store) }
        .confirmationDialog("删掉这张？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let p = confirmDelete { Task { await store.delete(p, api: session.api) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片和它写的字一起删，删了找不回来。")
        }
    }

    private func companionName(_ id: UUID) -> String { names[id] ?? "Ta" }

    private func open(_ frames: [FilmFrame], at i: Int) {
        viewer = AlbumViewerJob(frames: frames, start: i)
    }

    /// 长按一格：收藏 / 隐私 / 删（只在真相册里）
    @ViewBuilder
    private func menu(_ f: FilmFrame) -> some View {
        if let p = f.photo {
            Button { Task { await store.set(p, starred: !p.starred, api: session.api) } } label: {
                Label(p.starred ? "取消收藏" : "收藏", systemImage: p.starred ? "star.slash" : "star")
            }
            Button { Task { await store.set(p, secret: !p.secret, api: session.api) } } label: {
                Label(p.secret ? "移出隐私" : "放进隐私", systemImage: p.secret ? "lock.open" : "lock")
            }
            Button(role: .destructive) { confirmDelete = p } label: { Label("删掉", systemImage: "trash") }
        }
    }

    // MARK: 顶上

    /// 顶上一行：‹ 回去 · 年份（宫格时写「全部照片」）· 切宫格（10-02 Tilia：三本的标签挪到下面，上面才平衡）
    private var topBar: some View {
        ZStack {
            if grid {
                Text("全部照片").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            } else {
                yearBar
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(Typo.icon(16, .semibold)).foregroundStyle(theme.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.4)))
                }
                Spacer()
                if live {
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(Typo.icon(16, .semibold)).foregroundStyle(theme.accentDeep)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.4)))
                    }
                    .accessibilityLabel("放照片进相册")
                }
                Button {
                    withAnimation(.snappy(duration: 0.25)) { grid.toggle() }
                } label: {
                    Image(systemName: grid ? "film" : "square.grid.3x3")
                        .font(Typo.icon(16)).foregroundStyle(theme.accentDeep)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.4)))
                }
                .accessibilityLabel(grid ? "按月看" : "看全部照片")
            }
        }
        .padding(.horizontal, 14)
    }

    /// 三本：浮在底部的一条胶囊
    private var bookBar: some View {
        HStack(spacing: 4) {
            ForEach(AlbumBook.allCases, id: \.self) { b in
                Button {
                    if b == .secret && !unlocked { Task { await unlock() } } else { withAnimation(.snappy(duration: 0.2)) { book = b } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: b.icon).font(Typo.icon(10))
                        Text(b.label).font(Typo.sans(Typo.Size.callout, book == b ? .semibold : .regular))
                    }
                    .foregroundStyle(book == b ? Color.white : theme.inkDim)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(book == b ? theme.accentDeep : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.8))
        .shadow(color: theme.accentDeep.opacity(0.12), radius: 10, y: 4)
    }

    private var yearBar: some View {
        let i = years.firstIndex(of: year) ?? 0
        return HStack(spacing: 22) {
            Button { year = years[max(0, i - 1)] } label: { Image(systemName: "chevron.left") }
                .opacity(i > 0 ? 1 : 0.25).disabled(i == 0)
            Text(String(year)).font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
                .contentTransition(.numericText())
            Button { year = years[min(years.count - 1, i + 1)] } label: { Image(systemName: "chevron.right") }
                .opacity(i < years.count - 1 ? 1 : 0.25).disabled(i >= years.count - 1)
        }
        .font(Typo.icon(15, .semibold))
        .foregroundStyle(theme.accentDeep)
        .animation(.snappy, value: year)
    }

    private var lockedPane: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(Typo.icon(30)).foregroundStyle(theme.inkFaint)
            Text("这本锁着").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Button { Task { await unlock() } } label: {
                Text("解锁").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(Capsule().fill(theme.accentDeep))
            }
            Spacer()
        }
        .padding(.top, 70)
    }

    /// Face ID（没有就退回手机密码）。只在这次打开相册时有效
    private func unlock() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "打开隐私相册"))) == true {
            unlocked = true
            book = .secret
        }
    }

    // MARK: 一年十二个月

    private var monthsView: some View {
        let m = FilmMetrics.small
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        // 十二个月在年份下面那块里上下居中（10-02 Tilia：下面有点空）；屏幕矮放不下就照常滚
        return GeometryReader { geo in
            ScrollView {
                VStack(spacing: 18) {
                    LazyVGrid(columns: cols, spacing: 26) {
                        ForEach(1...12, id: \.self) { month in
                            let r = roll(month)
                            let hidden = lifted?.roll.id == r.id
                            FilmPile(roll: r, metrics: m, open: .constant(false))
                                .frame(width: m.cellW + 26, height: m.cellH + FilmPile.tabH + 12, alignment: .topLeading)
                                .opacity(hidden ? 0 : (r.frames.isEmpty ? 0.55 : 1))
                                .contentShape(Rectangle())
                                // 从手指点的地方飞起来（原来记每一打的位置，刚打开时常常还没记上，点了没反应）
                                .gesture(SpatialTapGesture(coordinateSpace: .named("album")).onEnded { lift(r, at: $0.location) })
                        }
                    }
                    .padding(.horizontal, 14)
                    if !live {
                        Text("样子预览 · 照片是画出来的")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    } else if store.loaded.contains(book) && shown.isEmpty {
                        Text(emptyText)
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                }
                .padding(.top, 16).padding(.bottom, 70)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    // MARK: 点开：飞到中间、后面糊上、横向摊开

    private func lift(_ r: FilmRoll, at point: CGPoint) {
        guard !r.frames.isEmpty, lifted == nil else { return }
        let m = FilmMetrics.small
        let rect = CGRect(x: point.x - m.cellW / 2, y: point.y - FilmPile.tabH - m.cellH / 2, width: m.cellW, height: m.cellH)
        liftedOpen = false
        landed = false
        stripX = 0
        stripDrag = 0
        lifted = Lifted(roll: r, from: rect)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { landed = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { liftedOpen = true }
    }

    private func drop() {
        liftedOpen = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { stripX = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { landed = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { lifted = nil }
        }
    }

    /// 点在摊开那条的某一格上 = 看那一格；点别处 = 收回去。两层（那条自己、后面的磨砂）谁收到点击都走这里，按屏幕坐标算
    private func pickOrDrop(at p: CGPoint, _ l: Lifted, _ m: FilmMetrics, _ side: CGFloat) {
        let left = stripRow.minX + side + stripX, top = stripRow.minY + FilmPile.tabH
        if liftedOpen, p.y >= top, p.y <= top + m.cellH, p.x >= left {
            let i = Int((p.x - left) / (m.cellW - 1))
            if l.roll.frames.indices.contains(i) { open(l.roll.frames, at: i); return }
        }
        if liftedOpen, p.y >= top - FilmPile.tabH, p.y <= top + m.cellH, p.x >= left { return }   // 点在那条上但不在格子里（标签、缝）：不收
        drop()
    }

    private func liftedLayer(_ l: Lifted) -> some View {
        GeometryReader { geo in
            let m = FilmMetrics.big
            let page = geo.frame(in: .named("album"))
            let side = max(16, (geo.size.width - m.cellW) / 2)
            let rowH = m.cellH + FilmPile.tabH + 8
            // 大打第一张的中心（落点）和小打第一张的中心（起点），都换成这一层自己的坐标
            let to = CGPoint(x: side + m.cellW / 2, y: geo.size.height * 0.42)
            let from = CGPoint(x: l.from.minX - page.minX + FilmMetrics.small.cellW / 2,
                               y: l.from.minY - page.minY + FilmPile.tabH + FilmMetrics.small.cellH / 2)
            let scale = FilmMetrics.small.k / m.k
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.ultraThinMaterial)
                    .opacity(landed ? 1 : 0)
                    .ignoresSafeArea()
                    // 点在摊开那条上 = 看那一格；点别处 = 收回去。按位置算，不靠那条自己收点击
                    //（模拟器里那条怎么挂点击都被这层磨砂抢走，10-02）
                    .gesture(SpatialTapGesture(coordinateSpace: .global).onEnded { pickOrDrop(at: $0.location, l, m, side) })
                // 横着滑不用 ScrollView：自己按手指挪（照之前自用的 App看图页）。用 ScrollView 时格子收不到点击（10-02 模拟器里试出来的），
                // 点哪一格按点的位置算
                let total = CGFloat(l.roll.frames.count) * (m.cellW - 1)
                let minX = min(0, -(total - m.cellW))
                FilmPile(roll: l.roll, metrics: m, open: $liftedOpen, onToggle: { open in if !open { drop() } },
                         onPick: nil, menu: live ? { f in AnyView(menu(f)) } : nil)
                    .contentShape(Rectangle())
                    .offset(x: side + stripX + stripDrag)
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in if liftedOpen { stripDrag = v.translation.width } }
                            .onEnded { v in
                                guard liftedOpen else { return }
                                let end = stripX + v.translation.width + (v.predictedEndTranslation.width - v.translation.width) * 0.5
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                    stripX = max(minX, min(0, end))
                                    stripDrag = 0
                                }
                            }
                    )
                    .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { pickOrDrop(at: $0.location, l, m, side) })
                    .frame(width: geo.size.width, height: rowH, alignment: .topLeading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripRow = $0 }
                    // 以第一张的中心为支点缩放，再把这个点从小打的位置挪到落点
                    .scaleEffect(landed ? 1 : scale,
                                 anchor: UnitPoint(x: to.x / geo.size.width, y: (FilmPile.tabH + m.cellH / 2) / rowH))
                    .offset(x: landed ? 0 : from.x - to.x, y: landed ? 0 : from.y - to.y)
                    .padding(.top, to.y - (FilmPile.tabH + m.cellH / 2))
                if landed {
                    VStack(spacing: 6) {
                        Text(l.roll.month.formatted(.dateTime.year().month(.wide)))
                            .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                        Text("\(l.roll.frames.count) 张 · 左右滑")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                    .frame(maxWidth: .infinity)
                    .offset(y: to.y + m.cellH / 2 + 34)
                    .transition(.opacity)
                    Button { drop() } label: {
                        Image(systemName: "xmark").font(Typo.icon(14, .semibold)).foregroundStyle(theme.inkDim)
                            .frame(width: 38, height: 38).background(Circle().fill(Color.white.opacity(0.5)))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16).padding(.top, 8)
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: 宫格（全部照片）

    private var emptyText: String {
        switch book {
        case .all: String(localized: "相册还空着。聊天里你发的照片，它觉得值得留就会收进来；右上角 ＋ 也可以自己放。")
        case .starred: String(localized: "还没有收藏的。长按一张照片可以收藏。")
        case .secret: String(localized: "隐私相册是空的。长按一张照片可以放进来，放进来的在别处都看不见。")
        }
    }

    private var gridView: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        let list = shown.sorted { $0.date > $1.date }
        return ScrollView {
            if live && store.loaded.contains(book) && list.isEmpty {
                Text(emptyText).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    .multilineTextAlignment(.center).padding(40)
            }
            LazyVGrid(columns: cols, spacing: 3) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, f in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(f.picture())
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { open(list, at: i) }
                        .contextMenu { menu(f) }
                        .overlay(alignment: .topTrailing) {
                            if f.starred {
                                Image(systemName: "star.fill").font(Typo.icon(10)).foregroundStyle(.white)
                                    .shadow(radius: 2).padding(5)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 70)
        }
    }
}

/// 摊开的那一打才给每格挂「点一下看图 / 长按菜单」：月历上的小打不挂，不然会吃掉「点一打」那一下
private struct FramePick: ViewModifier {
    let on: Bool
    let open: Bool
    let pick: () -> Void
    let menu: AnyView?

    func body(content: Content) -> some View {
        if on {
            content
                .contentShape(Rectangle())          // 每格是 drawingGroup 画成的一张图，不给形状就点不中
                .onTapGesture { if open { pick() } }
                .contextMenu { if open, let menu { menu } }
        } else {
            content
        }
    }
}

/// 一打胶片：叠着 / 横向摊开。标签粘在第一张上沿，摊开时点标签收回（onToggle）
struct FilmPile: View {
    @EnvironmentObject private var theme: AppTheme
    let roll: FilmRoll
    let metrics: FilmMetrics
    @Binding var open: Bool
    var onToggle: ((Bool) -> Void)? = nil
    /// 摊开时点一格（看图页）、长按一格（收藏 / 隐私 / 删）；月历上的小打不给
    var onPick: ((Int) -> Void)? = nil
    var menu: ((FilmFrame) -> AnyView)? = nil

    static let tabH: CGFloat = 20

    var body: some View {
        let m = metrics
        let n = roll.frames.count
        ZStack(alignment: .topLeading) {
            if n == 0 {
                RoundedRectangle(cornerRadius: 5 * m.k, style: .continuous)
                    .strokeBorder(theme.accentDeep.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: m.cellW, height: m.cellH)
                    .overlay(alignment: .topLeading) { tab(empty: true) }
            }
            ForEach(Array(roll.frames.enumerated()).reversed(), id: \.element.id) { i, f in
                FilmCell(frame: f, number: i + 1, metrics: m)
                    .overlay(alignment: .topLeading) { if i == 0 { tab(empty: false) } }
                    .rotationEffect(.degrees(open ? 0 : tilt(i)))
                    .offset(x: open ? CGFloat(i) * (m.cellW - 1) : CGFloat(min(i, 4)) * 5 * m.k,
                            y: open ? 0 : CGFloat(min(i, 4)) * 3 * m.k)
                    .shadow(color: theme.accentDeep.opacity(open ? 0 : 0.16), radius: open ? 0 : 6, y: 3)
                    .animation(.spring(response: 0.55, dampingFraction: 0.82)
                               .delay(open ? Double(i) * 0.035 : Double(n - i) * 0.02), value: open)
                    .modifier(FramePick(on: onPick != nil, open: open, pick: { onPick?(i) }, menu: menu?(f)))
            }
            if !open && n > 0 {
                Text("\(n)")
                    .font(Typo.number(Typo.Size.caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.accentDeep))
                    .offset(x: m.cellW + 2, y: -6)
            }
        }
        .padding(.top, Self.tabH)
        .frame(width: open ? max(1, CGFloat(n)) * (m.cellW - 1) : m.cellW + 20, height: m.cellH + Self.tabH + 8,
               alignment: .topLeading)
    }

    private func tilt(_ i: Int) -> Double {
        i == 0 ? 0 : [-4, 3, -2, 5, -3][i % 5]
    }

    /// 月份：一枚书页小标签，粘在第一张的上沿
    private func tab(empty: Bool) -> some View {
        let thisYear = Calendar.current.isDate(roll.month, equalTo: Date(), toGranularity: .year)
        let year = thisYear || metrics.k < 1 ? "" : " " + roll.month.formatted(.dateTime.year())
        return Text(roll.month.formatted(.dateTime.month(.abbreviated)) + year)
            .font(Typo.sans(Typo.Size.caption, .semibold))
            .foregroundStyle(empty ? theme.accentDeep.opacity(0.6) : .white)
            .padding(.horizontal, 9)
            .frame(height: Self.tabH + 5, alignment: .top)
            .padding(.top, 3)
            .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                .fill(empty ? Color.white.opacity(0.35) : theme.accentDeep.opacity(0.9)))
            .offset(x: 10 * metrics.k, y: -Self.tabH)
            .onTapGesture {
                guard !empty, let onToggle else { return }
                open.toggle()
                onToggle(open)
            }
            .allowsHitTesting(onToggle != nil)
    }
}

/// 一格：上下片边（镂空齿孔）+ 照片 + 角上的日期。片基 = 白纱 + 主题色半透明
struct FilmCell: View {
    @EnvironmentObject private var theme: AppTheme
    let frame: FilmFrame
    let number: Int
    let metrics: FilmMetrics

    var body: some View {
        let m = metrics
        VStack(spacing: 0) {
            edge(number % 3 == 1 ? "MELE 400" : " ", alignment: .bottomLeading)
            frame.picture()
                .frame(width: m.frameW, height: m.frameH)
                .clipped()
                .overlay(alignment: .bottomTrailing) { if m.k >= 1 { stamp } }
                .clipShape(RoundedRectangle(cornerRadius: 3 * m.k, style: .continuous))
            edge("\(number)  ▸", alignment: .topLeading)
        }
        .frame(width: m.cellW, height: m.cellH)
        .background { base }
        .drawingGroup()          // 一格画成一张图再挪（镂空的蒙版、日期的晕不用每帧重算）
    }

    /// 片边的字（片名、格号）：小打上就不印了，太小看不清
    private func edge(_ text: String, alignment: Alignment) -> some View {
        Text(metrics.k >= 1 ? text : " ")
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.accentDeep.opacity(0.75))
            .padding(.leading, 12)
            .frame(width: metrics.cellW, height: metrics.rail, alignment: alignment)
    }

    /// 片基：白纱 + 主题色，齿孔真的挖空（destinationOut），能看见后面
    private var base: some View {
        let m = metrics
        let shape = RoundedRectangle(cornerRadius: 5 * m.k, style: .continuous)
        let inset = (m.rail - 8 * m.k) / 2
        // 不用实时磨砂（每格一块 material 横滑时一帧要糊好几块，10-02 Tilia说卡）：白纱 + 主题色，后面本来就是糊的
        return ZStack {
            shape.fill(Color.white.opacity(0.42))
            shape.fill(theme.accent.opacity(0.30))
            shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 0.8)
        }
        .mask {
            ZStack {
                shape.fill(.black)
                VStack(spacing: 0) {
                    holes.padding(.top, inset)
                    Spacer(minLength: 0)
                    holes.padding(.bottom, inset)
                }
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }

    private var holes: some View {
        let m = metrics
        let holeW = 7 * m.k, holeH = 8 * m.k, pitch = 13 * m.k
        let count = max(1, Int(m.cellW / pitch))
        return HStack(spacing: pitch - holeW) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5 * m.k, style: .continuous).frame(width: holeW, height: holeH)
            }
        }
        .frame(width: m.cellW)
    }

    /// 机背印的日期：'26 10 02，白字带一圈主题色的晕
    private var stamp: some View {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: frame.date)
        return Text(String(format: "'%02d %2d %2d", (c.year ?? 0) % 100, c.month ?? 0, c.day ?? 0))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .shadow(color: theme.accentDeep.opacity(0.9), radius: 2)
            .padding(.trailing, 6).padding(.bottom, 4)
    }
}

// MARK: - 假照片（样子预览用）

enum FilmDemo {
    static let cached = frames()

    static func frames() -> [FilmFrame] {
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year, from: now), mNow = cal.component(.month, from: now)
        let palettes: [[UIColor]] = [
            [UIColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1), UIColor(red: 0.93, green: 0.55, blue: 0.50, alpha: 1)],   // 傍晚
            [UIColor(red: 0.62, green: 0.80, blue: 0.93, alpha: 1), UIColor(red: 0.95, green: 0.95, blue: 0.90, alpha: 1)],   // 海边
            [UIColor(red: 0.55, green: 0.70, blue: 0.52, alpha: 1), UIColor(red: 0.92, green: 0.88, blue: 0.70, alpha: 1)],   // 公园
            [UIColor(red: 0.30, green: 0.28, blue: 0.45, alpha: 1), UIColor(red: 0.95, green: 0.72, blue: 0.55, alpha: 1)],   // 夜里的灯
            [UIColor(red: 0.96, green: 0.86, blue: 0.86, alpha: 1), UIColor(red: 0.80, green: 0.62, blue: 0.70, alpha: 1)],   // 花
            [UIColor(red: 0.85, green: 0.72, blue: 0.55, alpha: 1), UIColor(red: 0.55, green: 0.38, blue: 0.28, alpha: 1)],   // 咖啡
        ]
        // 今年：这个月往前几个月有照片，中间空几个月；去年：秋冬那几个月
        var plan: [(Int, Int, Int)] = []          // 年、月、张数
        for (back, n) in [(0, 7), (1, 5), (2, 9), (4, 4), (5, 6), (7, 3)] where mNow - back >= 1 { plan.append((y, mNow - back, n)) }
        for (m, n) in [(9, 5), (10, 8), (12, 4)] { plan.append((y - 1, m, n)) }
        var id = 0
        var out: [FilmFrame] = []
        for (yy, mm, n) in plan {
            for i in 0..<n {
                id += 1
                let day = min(1 + i * 3, 28)
                let date = cal.date(from: DateComponents(year: yy, month: mm, day: day, hour: 18)) ?? now
                out.append(FilmFrame(id: id, date: date, image: picture(palettes[(i + mm) % palettes.count], seed: id),
                                     starred: id % 4 == 0, secret: id % 9 == 0))
            }
        }
        return out
    }

    /// 两色渐变 + 一个柔光圆 + 一条地平线，像一张虚焦的风景
    static func picture(_ colors: [UIColor], seed: Int) -> UIImage {
        let size = CGSize(width: 600, height: 400)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let x = CGFloat((seed * 97) % 420) + 90, y = CGFloat((seed * 53) % 160) + 60
            UIColor.white.withAlphaComponent(0.55).setFill()
            cg.fillEllipse(in: CGRect(x: x - 60, y: y - 60, width: 120, height: 120))
            colors[1].withAlphaComponent(0.55).setFill()
            cg.fill(CGRect(x: 0, y: size.height * 0.68, width: size.width, height: size.height * 0.32))
        }
    }
}
