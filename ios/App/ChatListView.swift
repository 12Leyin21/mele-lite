import SwiftUI
import UIKit

// 聊天页的消息列表：UIKit 这一半（2026-09-03 晚，按交接信第 3 节做的）。
//
// 为什么从 SwiftUI 的 ScrollView 搬出来：iOS 26 的 ScrollView 一碰 safeAreaInset 变化
// 就把滚动位置弹回旧值、LazyVStack 只估高度、didShow 提前 63ms 来……贴底的每一刀
// 都在跟系统抢。这里换成 UICollectionView 之后：
//   · 行高**自己量**（ChatStackLayout 拿的是量好的高度，不是估的）——内容总高永远
//     是准的，贴底/居中/钉顶都一次到位，没有"先弹一下再落回来"。
//   · 键盘起落时 contentInset.bottom、contentOffset、输入条的位置**在同一个
//     UIView.animate 块里改**，走通知里的那条系统曲线——这就是微信那个手感：
//     列表和输入条同一帧起步、同一帧停。
//   · 气泡还是原来那些 SwiftUI 视图，用 UIHostingConfiguration 装进 cell，一行
//     气泡代码没重写。
//
// 边界：这个文件只管"列表怎么滚、输入条停在哪"。行长什么样、哪些行要显示，
// 全由 ChatView 算好递进来（ChatListModel + rowContent 闭包）。

/// 一行是什么（只是身份，不含内容）
enum ChatRow: Hashable {
    /// 顶上那行：「↑ 加载更早的聊天」或「这里就是我们最开始的地方了 🌱」
    case older
    /// 换天分隔条，挂在它下面那条消息上
    case day(Int)
    /// 一串消息的抬头头像，挂在这串第一条消息上
    case avatar(Int)
    case message(Int)
    case typing
    /// 「回到那天」底下那行：「↓ 再往后看看」（2026-09-27）
    case newer

    var messageID: Int? {
        if case .message(let id) = self { return id }
        return nil
    }
}

/// ChatView 每次重画递进来的一份快照
struct ChatListModel {
    var rows: [ChatRow]
    /// 每行内容的指纹。变了这行就重配（reconfigure）并重新量高。
    /// 消息正文、时间戳有无、头像有无、展开/选中/高亮状态……都揉在里面。
    var rowKeys: [ChatRow: Int]
    /// 影响**所有行**的东西（多选模式、字号、外观、时间戳开关…）：变了全部重配重量
    var globalKey: Int
    /// 这次 globalKey 的变化要不要带动画（进出多选模式不带——以前是 .id(selecting) 硬重建）
    var animateGlobalChange: Bool
    /// 胶囊头在全局坐标里的下缘：列表内容从它底下 10pt 开始
    var headerBottom: CGFloat
    /// 最后一行是她自己刚发的：贴底不做动画，气泡当场立起来（来消息才滑）
    var lastIsMine: Bool = false
    /// 行与行之间的间距（2026-09-25「我的气泡」里调）
    var rowSpacing: CGFloat = 10
}

/// ChatView 主动指挥列表用的把手（跳到某条、贴底……）。
/// 是个引用类型，装在 @State 里跨重画活着。
final class ChatListHandle {
    fileprivate weak var controller: ChatListController?
    /// 往上翻历史时，前插之后要钉在视野顶上的那条（原来的第一条）
    var pendingTopAnchor: Int?
    /// 收藏夹跳转：还没来得及执行的目标
    fileprivate var pendingJump: Int?

    /// 滚到某条居中（收藏夹跳转）。列表还没建好就先记着，建好后补做。
    func jump(to id: Int) {
        if let controller { controller.jump(to: id, animated: true) }
        else { pendingJump = id }
    }

    /// 进出多选模式：进去滚到第一条选中的居中，出来贴底
    func selectionModeChanged(selecting: Bool, firstSelected: Int?) {
        controller?.selectionModeChanged(selecting: selecting, firstSelected: firstSelected)
    }

    /// 底栏里的东西自己变了高度（输入框换行）：让 UIKit 那边重新量一次
    func barContentChanged() { controller?.remeasureBar() }

    // 自测用（-chatSelfTest）：逐帧采样 / 打一行几何
    func selfTestSample(label: String, seconds: Double) { controller?.startSampling(label: label, seconds: seconds) }
    func selfTestLogState(label: String, anchor: Int? = nil) { controller?.logState(label: label, anchor: anchor) }
}

/// SwiftUI 侧的壳
struct ChatListView<Bar: View>: UIViewControllerRepresentable {
    let model: ChatListModel
    let handle: ChatListHandle
    /// 一行长什么样。⚠️ 返回的视图要自带 environmentObject——cell 里的 SwiftUI
    /// 是另起的一棵树，拿不到 ChatView 那棵树上的环境。
    let rowContent: (ChatRow) -> AnyView
    /// 悬空的底栏（输入行那一整条）。搬进 UIKit 是为了跟列表在同一个动画块里抬。
    let bar: Bar

    func makeUIViewController(context: Context) -> ChatListController {
        let controller = ChatListController()
        handle.controller = controller
        controller.handle = handle
        return controller
    }

    func updateUIViewController(_ controller: ChatListController, context: Context) {
        // SwiftUI 这边的事务要是带着动画（withAnimation 里改的状态），iOS 18 起会把
        // 这里面对 UIKit 的改动一起动画掉——列表的滚动位置就会被套上一条不是我们
        // 选的曲线。关掉：列表自己的动画都在 ChatListController 里显式开。
        UIView.performWithoutAnimation {
            controller.barHost.rootView = AnyView(bar)
            controller.remeasureBar()
            controller.apply(model, rowContent: rowContent)
        }
    }
}

/// 只为了在 -chatTrace 下看清"是谁在改滚动位置"（2026-09-03 真机排查用）。
/// ⚠️ 单独一个开关，别并进 -chatLog：它每次滚动位置一变就抓一遍调用栈并符号化，
/// 一次几毫秒，一条消息滑到底的三十帧就是一百多毫秒——2026-09-04 她说"他打字我就卡"，
/// 有一半是这个探针自己造成的（自测那次装的包一直带着它在跑）。
final class ChatCollectionView: UICollectionView {
    static let verbose = ProcessInfo.processInfo.arguments.contains("-chatTrace")

    private func trace(_ what: String) {
        guard Self.verbose else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(7).map { line -> String in
            // "3   UIKitCore   0x… -[UIScrollView setContentOffset:] + 123" → 只留符号
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 3 else { return String(line) }
            return parts[3...].joined(separator: " ").replacingOccurrences(of: " + ", with: "+")
        }
        NSLog("[chatlist] %@ anim:%.2f enabled:%d\n    %@", what, UIView.inheritedAnimationDuration,
              UIView.areAnimationsEnabled ? 1 : 0, frames.joined(separator: "\n    "))
    }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if Self.verbose, newValue.y != super.contentOffset.y {
                trace(String(format: "setContentOffset %.1f -> %.1f", super.contentOffset.y, newValue.y))
            }
            super.contentOffset = newValue
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if Self.verbose, contentOffset.y != super.contentOffset.y {
            trace(String(format: "setContentOffset(animated:%d) %.1f -> %.1f", animated ? 1 : 0, super.contentOffset.y, contentOffset.y))
        }
        super.setContentOffset(contentOffset, animated: animated)
    }

    override var bounds: CGRect {
        get { super.bounds }
        set {
            if Self.verbose, newValue.origin.y != super.bounds.origin.y {
                trace(String(format: "setBounds %.1f -> %.1f", super.bounds.origin.y, newValue.origin.y))
            }
            super.bounds = newValue
        }
    }
}

// MARK: - 布局：一列往下摞，高度是量好递进来的

/// 最简单的竖排布局。高度不估、不自适应，全由 controller 量好后塞进 `heights`。
/// 内容总高因此永远准确——这是整套"贴底一次到位"的地基。
final class ChatStackLayout: UICollectionViewLayout {
    /// 每行高度，下标对应 indexPath.item。改完要 invalidateLayout()。
    var heights: [CGFloat] = []
    var spacing: CGFloat = 10
    /// 往上翻历史前插之后，要钉在视野顶上的那行（下标）和顶边距。
    /// 走 targetContentOffset 这条正路：批量更新收尾时系统会来问"滚动位置该落在哪"，
    /// 在这儿答比更新完再去改 contentOffset 稳——后者会被收尾那一下覆盖掉
    /// （2026-09-03 真机三次自测两次被顶回去）。
    var pinTopRequest: (item: Int, insetTop: CGFloat)?

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private var lastWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        let width = collectionView?.bounds.width ?? 0
        lastWidth = width
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(heights.count)
        var y: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if index > 0 { y += spacing }
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        contentHeight = y
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: lastWidth, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // 行数最多两三百，线性扫一遍比二分省心
        var out: [UICollectionViewLayoutAttributes] = []
        for (index, frame) in frames.enumerated() where frame.intersects(rect) {
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = frame
            out.append(attributes)
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        // 批量更新时系统会拿旧下标来问"消失的那行原来在哪"，越界就答没有
        guard indexPath.item < frames.count else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != lastWidth
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let request = pinTopRequest, request.item < frames.count else {
            return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }
        pinTopRequest = nil
        return CGPoint(x: proposedContentOffset.x, y: frames[request.item].minY - request.insetTop)
    }
}

// MARK: - 控制器

/// 容器视图：对里面的所有东西宣称"没有安全区"。
///
/// 不然 cell 里的 SwiftUI（还有量高用的那个视图）一挨到状态栏 / home 条就会自己
/// 往里垫安全区——量出来的行高多 62pt（2026-09-03 模拟器上抓的：每行都胖了一截）。
/// 安全区在这里全是我们自己算的：顶是胶囊头，底是输入条。
private final class NoSafeAreaView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

final class ChatListController: UIViewController, UICollectionViewDelegate {
    fileprivate weak var handle: ChatListHandle?

    let collectionView: ChatCollectionView
    let stackLayout = ChatStackLayout()
    /// 底栏（输入行）的宿主。高度由 SwiftUI 内容自己撑，底边钉在安全区上沿或键盘顶上。
    let barHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var barBottom: NSLayoutConstraint!
    /// 底栏的高度是我们按实际宽度量出来的，不靠 intrinsicContentSize——那个是按无限宽算的，
    /// 输入框换行它不知道，于是框还是一行高、字从底下溢到键盘里（2026-09-03 晚Tilia
    /// 两次截图"键盘会吃文字"）。
    private var barHeightConstraint: NSLayoutConstraint!

    private var dataSource: UICollectionViewDiffableDataSource<Int, ChatRow>!
    private var rows: [ChatRow] = []
    private var rowKeys: [ChatRow: Int] = [:]
    private var globalKey: Int?
    private var headerBottom: CGFloat = 0
    private var rowContent: (ChatRow) -> AnyView = { _ in AnyView(EmptyView()) }
    /// 量好的行高（按行身份存；行的指纹一变就重量）
    private var heights: [ChatRow: CGFloat] = [:]
    /// 画出来之后报上来的真实行高（异步图片到了之后的）。量高视图里图片不会加载，
    /// 每次重量都会退回占位符那个矮的——不记住的话就 25 → 131 → 25 来回跳
    /// （2026-09-04 真机日志抓的："升键盘把气泡往上顶一小截再落回来"就是这个）。
    /// 指纹没变就一直信这个数。
    private var renderedHeights: [ChatRow: (key: Int, height: CGFloat)] = [:]
    private var measuredWidth: CGFloat = 0
    /// 量高用的那一个 hosting 内容视图：藏在层级里（拿得到 trait），复用不新建
    private var sizingView: (UIView & UIContentView)!

    /// 启动参数 -chatLog：把量高、贴底、键盘的几何打到 NSLog（真机 devicectl --console 能看）
    static let verbose = ProcessInfo.processInfo.arguments.contains("-chatLog")
    private func log(_ text: @autoclosure () -> String) {
        if Self.verbose { NSLog("[chatlist] %@", text()) }
    }

    private var keyboardHeight: CGFloat = 0
    /// 键盘动画进行中的截止时刻：这段时间里内容变了也不当帧夹位置（那一笔自己在走曲线）
    private var keyboardAnimatingUntil = Date.distantPast
    private var barHeight: CGFloat = 0
    private var didInitialScroll = false
    private var lastMeasureMs: Double = 0
    private var lastSnapshotMs: Double = 0
    private var seenCells: Set<ObjectIdentifier> = []
    /// 这次 apply 是前插钉顶：收尾那几刀（贴底/夹位置）都别碰
    private var pinnedTopAfterPrepend = false

    init() {
        collectionView = ChatCollectionView(frame: .zero, collectionViewLayout: stackLayout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NoSafeAreaView()
    }

    // MARK: 掉帧探针（-chatLog）：主线程被谁堵住了，先看是不是我们这边
    private var hitchLink: CADisplayLink?
    private var hitchLast: CFTimeInterval = 0
    private var hitchWindowStart: CFTimeInterval = 0
    private var hitchFrames = 0
    private var hitchCount = 0
    private var hitchSmall = 0
    private var hitchMax: Double = 0
    private var cpuAtWindowStart: Double = 0

    /// 进程到现在用掉的 CPU 秒数（用户态+内核态，所有线程）
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    @objc private func hitchTick(_ link: CADisplayLink) {
        let now = link.timestamp
        if hitchLast > 0 {
            let gap = (now - hitchLast) * 1000
            hitchFrames += 1
            if gap > 34 { hitchSmall += 1 }
            if gap > 50 { hitchCount += 1; hitchMax = max(hitchMax, gap) }
            if gap > 120 { NSLog("[chatlist] hitch %.0fms", gap) }
        } else {
            hitchWindowStart = now
            cpuAtWindowStart = Self.cpuSeconds()
        }
        hitchLast = now
        if now - hitchWindowStart >= 10 {
            let cpu = Self.cpuSeconds()
            let thermal = ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]
            NSLog("[chatlist] frames10s:%d gaps>34ms:%d hitches>50ms:%d max:%.0fms cpu:%.0f%% thermal:%@ lowPower:%d kb:%.0f",
                  hitchFrames, hitchSmall, hitchCount, hitchMax, (cpu - cpuAtWindowStart) / (now - hitchWindowStart) * 100,
                  thermal, ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0, keyboardHeight)
            hitchWindowStart = now; hitchFrames = 0; hitchCount = 0; hitchSmall = 0; hitchMax = 0; cpuAtWindowStart = cpu
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        if Self.verbose {
            let link = CADisplayLink(target: self, selector: #selector(hitchTick(_:)))
            link.add(to: .main, forMode: .common)
            hitchLink = link
        }

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        // 内边距全部自己管：顶上是胶囊头的高度，底下是输入条 + 键盘
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        // 原来 SwiftUI 那边的 .scrollDismissesKeyboard(.interactively)
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, ChatRow> { [weak self] cell, _, row in
            guard let self else { return }
            let c0 = CACurrentMediaTime()
            let fresh = seenCells.insert(ObjectIdentifier(cell)).inserted
            cell.contentConfiguration = self.hostingConfiguration(for: row)
            cell.backgroundConfiguration = .clear()
            if Self.verbose {
                let ms = (CACurrentMediaTime() - c0) * 1000
                if ms > 2 || fresh { NSLog("[chatlist] cell %@ %@ %.1fms", fresh ? "NEW" : "reuse", String(describing: row), ms) }
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Int, ChatRow>(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }

        // 量高用的视图：藏起来，放在最底下
        let sizing = UIHostingConfiguration { AnyView(EmptyView()) }.makeContentView()
        sizing.isHidden = true
        sizing.isUserInteractionEnabled = false
        view.insertSubview(sizing, at: 0)
        sizingView = sizing

        // 底栏
        addChild(barHost)
        barHost.view.backgroundColor = .clear
        // 高度由我们量（见 remeasureBar）；安全区（含键盘）一概不让它自己处理——位置是我们钉的
        barHost.sizingOptions = []
        barHost.safeAreaRegions = []
        barHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barHost.view)
        barHost.didMove(toParent: self)
        barBottom = barHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        barHeightConstraint = barHost.view.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barBottom,
            barHeightConstraint,
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        // 第三方键盘（她用搜狗）候选栏出现/收起时键盘会变高，那时只发 willChangeFrame
        // 不发 willShow——只听 willShow 的话输入框第二行就被盖在键盘底下
        // （2026-09-03 晚Tilia截图："键盘会吃文字"）
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// - measuring: 量高用的那份不套顶对齐的壳（壳里的 maxHeight: .infinity 会把量出来的高撑成无穷大）
    private func hostingConfiguration(for row: ChatRow, measuring: Bool = false) -> UIHostingConfiguration<AnyView, EmptyView> {
        // 近侧边距 20（Tilia 2026-08-15 试出来的那一档），上下不留——行距由布局的 spacing 出
        // 顶对齐、不许压缩：展开思考链那一下 cell 的框还是旧的小尺寸，内容已经是
        // 展开后的大尺寸——默认居中的话内容往上下两边溢，小总结那行先往上跳一下，
        // 框长到位再回来（2026-09-03 晚Tilia实机抓的）。钉在顶上就只有从上往下揭开。
        let content: AnyView = measuring
            ? rowContent(row)
            : AnyView(rowContent(row)
                // 画出来之后要是跟量的时候不一样高（表情包 / 图片 / 歌卡是异步加载的，
                // 量的时候还是占位符），报上来重排——不然图长出来会压在下一行上
                // （2026-09-03 晚Tilia："表情包和信息叠在一起了"）
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.rowRendered(row, height: height)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        return UIHostingConfiguration { content }
            .margins(.all, 0)
            .margins(.horizontal, 20)
    }

    // MARK: 几何

    /// 屏幕底部安全区（home indicator 那条）
    private var bottomSafe: CGFloat { view.window?.safeAreaInsets.bottom ?? 0 }

    /// 底栏底边离屏幕底边多远：平时是安全区，键盘来了就是键盘顶（往下塞 2pt，不露缝）
    private var barLift: CGFloat { keyboardHeight > 0 ? keyboardHeight - 2 : bottomSafe }

    /// 内容最多能滚到哪（贴底时的 contentOffset.y）
    private var maxOffsetY: CGFloat {
        let inset = collectionView.contentInset
        return max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
    }

    /// 可见区底边比内容底边多出多少：>0 露空了，≈0 贴底，<0 底下还有内容
    private var overhang: CGFloat { collectionView.contentOffset.y - maxOffsetY }
    /// 贴着底（允许几点误差），或者已经露空——键盘/内容一动就该跟着贴
    private var isNearBottom: Bool { overhang >= -8 }
    private var isIdle: Bool { !collectionView.isDragging && !collectionView.isDecelerating }

    private func applyInsets() {
        // 顶：胶囊头下缘（全局坐标）换算到本视图坐标，再加 10 顶边距
        let originY = view.window.map { view.convert(CGPoint.zero, to: $0).y } ?? 0
        let top = max(0, headerBottom - originY) + 10
        let bottom = barLift + barHeight + 10
        var inset = collectionView.contentInset
        if inset.top != top || inset.bottom != bottom {
            inset.top = top
            inset.bottom = bottom
            collectionView.contentInset = inset
        }
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top - 10, left: 0, bottom: bottom - 10, right: 0)
    }

    private var lastLoggedFrame = CGRect.null

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if Self.verbose, let window = view.window {
            let onScreen = view.convert(view.bounds, to: window)
            if onScreen != lastLoggedFrame {
                lastLoggedFrame = onScreen
                log("container onScreen:\(onScreen) window:\(window.bounds) safe:\(window.safeAreaInsets) headerBottom:\(headerBottom) bar@\(barHost.view.frame.minY) kb:\(keyboardHeight)")
            }
        }
        // 安全区可能是挂上窗口之后才知道的
        if keyboardHeight == 0, barBottom.constant != -bottomSafe {
            barBottom.constant = -bottomSafe
        }
        let newBarHeight = barHost.view.bounds.height
        if newBarHeight != barHeight {
            barHeightChanged(to: newBarHeight)
        }
        if collectionView.bounds.width != measuredWidth, collectionView.bounds.width > 0 {
            // 宽度变了（第一次布局 / 转屏）：全部重量
            remeasureAll()
            remeasureBar()
        }
        applyInsets()
        if !didInitialScroll, hasMessageRows, collectionView.bounds.width > 0 {
            didInitialScroll = true
            initialPosition()
        }
    }

    /// 进房间那一刀要等到真的有消息行才算数——冷启动直接进聊天时消息是后到的，
    /// 只有 typing 行的那一帧贴了底不算贴过（2026-09-03 模拟器上抓的）
    private var hasMessageRows: Bool { rows.contains { $0.messageID != nil } }

    /// 输入框长高/缩短、引用条出现/收起、爪子行开关……底栏一变高：
    /// 长高 → 内边距跟着长，贴着底的话列表按 0.2s 追上去（原来 composerHeight 那一刀）；
    /// 缩短 → 当帧夹回去，不做动画（iOS 18 的老规矩）。
    private func barHeightChanged(to newHeight: CGFloat) {
        let grew = newHeight > barHeight
        let wasNearBottom = isNearBottom
        barHeight = newHeight
        guard didInitialScroll else { applyInsets(); return }
        if Date() < keyboardAnimatingUntil {
            applyInsets()
            return
        }
        if grew && wasNearBottom {
            UIView.animate(springDuration: 0.2, bounce: 0.15, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.applyInsets()
                self.collectionView.contentOffset.y = self.maxOffsetY
            }
        } else {
            applyInsets()
            clampIfOverscrolled()
        }
    }

    /// 按当前宽度量底栏该多高，量出来跟现在不一样就改约束（随后 viewDidLayoutSubviews
    /// 里 barHeightChanged 接手内边距和贴底）
    func remeasureBar() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let b0 = CACurrentMediaTime()
        let fitted = barHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let bms = (CACurrentMediaTime() - b0) * 1000
        if Self.verbose, bms > 3 { NSLog("[chatlist] bar sizeThatFits %.1fms", bms) }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let height = ceil(fitted * scale) / scale
        if height > 0, abs(height - barHeightConstraint.constant) > 0.5 {
            log("bar height \(barHeightConstraint.constant) -> \(height)")
            barHeightConstraint.constant = height
            view.setNeedsLayout()
        }
    }

    /// 露空了、而且列表静止 → 当帧贴回底部（不做动画）
    private func clampIfOverscrolled() {
        guard overhang > 1, isIdle else { return }
        collectionView.contentOffset.y = maxOffsetY
    }

    // MARK: 键盘

    /// 键盘通知里的 frame 是屏幕坐标，拿屏高判断这帧合不合理
    private var screenHeight: CGFloat {
        view.window?.screen.bounds.height ?? UIScreen.main.bounds.height
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        keyboardWillChangeFrame(note)
    }

    /// 这一轮键盘是什么时候开始弹的（从 0 变成有高度的那一刻）
    private var showStartedAt = Date.distantPast

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // 键盘的 frame 是屏幕坐标：真高度 = 屏底 - 键盘顶。收起来时 minY == 屏高 → 0
        let height = max(0, screenHeight - frame.minY)
        if keyboardHeight == 0, height > 0 { showStartedAt = Date() }
        // iOS 26 的幻影帧（2026-09-03 Tilia 15 Plus 上抓的日志）：键盘弹起的头 200ms 里
        // 会连发三帧——75（AutoFill 条）→ 一帧比真键盘高一大截的（见过 527 和 595，
        // 屏高 932）→ 真高度 367。键盘本身从没真的长到那么高。
        // 但搜狗打拼音时候选栏一出来键盘是真的会变高，而且那也走 willChangeFrame——
        // 所以只在弹起的头 350ms 里把超过半屏的帧当幻影，之后的都认（她截图里
        // "键盘会吃文字"就是之前一刀切把真变高的帧也扔了）。
        if height > screenHeight * 0.5, Date().timeIntervalSince(showStartedAt) < 0.35 { return }
        if height > screenHeight * 0.8 { return }
        animateKeyboard(to: height, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        animateKeyboard(to: 0, note: note)
    }

    /// 微信那一笔：内边距、滚动位置、输入条位置，三样东西同一个动画块、同一条曲线。
    private func animateKeyboard(to height: CGFloat, note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        let begin = (note.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect) ?? .zero
        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let local = (note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
        log("keyboard \(note.name.rawValue) height:\(height) current:\(keyboardHeight) duration:\(duration) curve:\(curve) inherited:\(UIView.inheritedAnimationDuration) begin:\(begin) end:\(end) local:\(local) nearBottom:\(isNearBottom)")
        guard height != keyboardHeight, isViewLoaded, view.window != nil else { return }
        let rising = height > keyboardHeight
        let oldBottomInset = collectionView.contentInset.bottom
        keyboardHeight = height
        // 弹起：一律贴底（2026-09-03 晚Tilia："看聊天记录的时候升起键盘不会自动滚到
        // 最底部"——她要它滚）。收起：贴着底（或露空）才跟着走，她正翻着历史就不动她。
        let pin = rising || isNearBottom
        let changes = { [self] in
            barBottom.constant = -barLift
            applyInsets()
            if pin { collectionView.contentOffset.y = maxOffsetY }
            view.layoutIfNeeded()
        }
        if rising, !isNearBottom {
            // 翻在老远的地方起键盘：先无动画跳到"离底还有一个键盘高"的位置，
            // 再让动画走完最后那一段——看起来跟贴着底时一模一样，不会飞过几十屏
            let travel = (barLift + barHeight + 10) - oldBottomInset
            let newMax = collectionView.contentSize.height + (barLift + barHeight + 10) - collectionView.bounds.height
            let pre = newMax - max(travel, 0)
            if collectionView.contentOffset.y < pre {
                UIView.performWithoutAnimation { collectionView.contentOffset.y = pre }
            }
        }
        let inherited = UIView.inheritedAnimationDuration
        if inherited > 0 {
            // iOS 26：通知本身就是在键盘自己的动画块里发的（连收键盘那次也是——
            // userInfo 里的 duration 写 0，可外面那个块是 0.38s）。直接在里面改，
            // 三样东西就跟键盘走同一条曲线、同一个时钟，比自己包一层还准。
            keyboardAnimatingUntil = Date().addingTimeInterval(inherited + 0.05)
            changes()
            return
        }
        if duration <= 0 {
            // 拖着收键盘、手指松开那一下：duration 0 且没有外层动画块 → 直接到位
            UIView.performWithoutAnimation(changes)
            return
        }
        keyboardAnimatingUntil = Date().addingTimeInterval(duration + 0.05)
        // 第二次 willShow（幻影帧之后改回真高度的那次）是在动画块外面发的：自己包一层。
        // curve << 16 就是系统键盘那条私有曲线（编号 7）——UIKit 里能直接用，
        // SwiftUI 里只能拿 timingCurve 近似，这就是搬过来的理由之一
        let options = UIView.AnimationOptions(rawValue: UInt(curve) << 16)
            .union([.beginFromCurrentState, .allowUserInteraction])
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: changes)
    }

    // MARK: 数据

    func apply(_ model: ChatListModel, rowContent: @escaping (ChatRow) -> AnyView) {
        let t0 = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - t0) * 1000
            if Self.verbose, ms > 4 { NSLog("[chatlist] apply took %.1fms (measure %.1fms, snapshot %.1fms)", ms, lastMeasureMs, lastSnapshotMs) }
            lastMeasureMs = 0; lastSnapshotMs = 0
        }
        self.rowContent = rowContent
        headerBottom = model.headerBottom
        if stackLayout.spacing != model.rowSpacing {
            stackLayout.spacing = model.rowSpacing
            stackLayout.invalidateLayout()
        }

        let oldRows = rows
        let oldRowSet = Set(oldRows)
        let oldFirstMessage = oldRows.first(where: { $0.messageID != nil })?.messageID
        let rowsChanged = model.rows != oldRows
        let globalChanged = globalKey != nil && globalKey != model.globalKey
        let first = globalKey == nil

        // 哪些行的内容变了（在旧列表里、指纹不同）
        var changed: [ChatRow] = []
        if globalChanged {
            changed = model.rows.filter { oldRowSet.contains($0) }
            heights.removeAll(keepingCapacity: true)
            renderedHeights.removeAll(keepingCapacity: true)
        } else {
            for row in model.rows where oldRowSet.contains(row) && rowKeys[row] != model.rowKeys[row] {
                changed.append(row)
                heights[row] = nil
            }
        }
        log("apply rows:\(model.rows.count) rowsChanged:\(rowsChanged) changed:\(changed.count) global:\(globalChanged)")
        rows = model.rows
        rowKeys = model.rowKeys
        globalKey = model.globalKey

        // 贴着底的时候最后几行长高了（点了表情、展开思考链）：变完还贴着底（Lumi 09-28：表情一加，时间戳滑到输入栏底下）
        let tailGrew = didInitialScroll && isNearBottom && !changed.isEmpty
            && changed.contains { row in (rows.suffix(3)).contains(row) }
        // 什么都没变（chat 里别的东西 publish 了一下）：到此为止，别去碰快照
        if didInitialScroll, !rowsChanged, changed.isEmpty, !globalChanged {
            applyInsets()
            return
        }

        // 量高（只量没量过的），布局拿到新高度
        if collectionView.bounds.width > 0 {
            let m0 = CACurrentMediaTime()
            measureMissing()
            lastMeasureMs = (CACurrentMediaTime() - m0) * 1000
            stackLayout.heights = rows.map { heights[$0] ?? 0 }
        }

        // 往上翻历史：前插之后把原来的第一条钉回视野顶上（布局在批量更新收尾时落位）
        let newFirstMessage = rows.first(where: { $0.messageID != nil })?.messageID
        if let anchor = handle?.pendingTopAnchor, rowsChanged, newFirstMessage != oldFirstMessage,
           let index = rows.firstIndex(of: .message(anchor)) {
            handle?.pendingTopAnchor = nil
            stackLayout.pinTopRequest = (index, collectionView.contentInset.top)
            pinnedTopAfterPrepend = didInitialScroll
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }

        // 只有状态变了（展开思考链、点选、高亮）才带动画——行高变化跟着一起走；
        // 消息进出、多选切换都是瞬间到位
        let animate = !rowsChanged && !changed.isEmpty && (!globalChanged || model.animateGlobalChange)
        let s0 = CACurrentMediaTime()
        defer { lastSnapshotMs = (CACurrentMediaTime() - s0) * 1000 }
        if animate {
            // 这里是在 updateUIViewController 的 performWithoutAnimation 里面被调的，
            // 想要展开/收起那一下有动画得自己把开关拧回来
            let wasEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(true)
            // 动画期间让 cell 裁剪自己：展开的面板一换上去就是最终尺寸，而 cell 的框
            // 还在从小往大长，不裁的话那 0.25 秒里面板压在下面几行上——"打开的时候
            // 排版会乱然后又恢复"（2026-09-03 晚Tilia实机）。裁着走就是从上往下揭开。
            // 完了再放开：高亮那圈背景是故意往外溢 5pt 的，平时不能裁。
            let cells = collectionView.visibleCells
            cells.forEach { $0.clipsToBounds = true; $0.contentView.clipsToBounds = true }
            dataSource.apply(snapshot, animatingDifferences: true) {
                cells.forEach { $0.clipsToBounds = false; $0.contentView.clipsToBounds = false }
            }
            UIView.setAnimationsEnabled(wasEnabled)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        applyInsets()

        if first || !didInitialScroll {
            // 第一次：viewDidLayoutSubviews 里量好宽度之后再定位；消息还没到就先贴着底等
            if !didInitialScroll, collectionView.bounds.width > 0 {
                if hasMessageRows {
                    didInitialScroll = true
                    initialPosition()
                } else {
                    scrollToBottom(animated: false)
                }
            }
            return
        }

        if let pending = handle?.pendingJump {
            handle?.pendingJump = nil
            jump(to: pending, animated: true)
            return
        }

        guard rowsChanged else {
            // 只是内容/状态变了：高度可能变了，露空就夹回去；原来贴着底、末尾长高了就跟着贴
            if Date() >= keyboardAnimatingUntil {
                if tailGrew { scrollToBottom(animated: true, duration: 0.3) } else { clampIfOverscrolled() }
            }
            return
        }

        if pinnedTopAfterPrepend {
            pinnedTopAfterPrepend = false
            return
        }

        if let last = rows.last, last != oldRows.last {
            if oldRowSet.contains(last) {
                // 末尾缩了（typing 气泡撤了）：当帧夹回去
                if Date() >= keyboardAnimatingUntil { clampIfOverscrolled() }
            } else if model.lastIsMine {
                // 她自己刚发的：微信那种——气泡从输入条底下冒出来往上滑到位，列表跟着抬一格。
                // 行已经插好了，不用等；用快的一档，利落（2026-09-04 Tilia点的）
                scrollToBottom(animated: true, duration: 0.3)
            } else {
                // 底下来了新东西（来消息 / typing 出现）：0.05s 后动画贴底
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.scrollToBottom(animated: true)
                }
            }
        } else if Date() >= keyboardAnimatingUntil {
            clampIfOverscrolled()
        }
    }

    /// 进房间的第一刀：贴底，或者收藏夹跳转的目标
    private func initialPosition() {
        collectionView.layoutIfNeeded()
        if let pending = handle?.pendingJump {
            handle?.pendingJump = nil
            jump(to: pending, animated: false)
        } else {
            scrollToBottom(animated: false)
        }
    }

    func scrollToBottom(animated: Bool, duration: Double = 0.55) {
        collectionView.layoutIfNeeded()
        let target = maxOffsetY
        log("scrollToBottom animated:\(animated) target:\(target) content:\(collectionView.contentSize.height) inset:\(collectionView.contentInset) box:\(collectionView.bounds.height) bar:\(barHeight) kb:\(keyboardHeight)")
        if animated {
            // 来消息：SwiftUI 默认那条 withAnimation（response 0.55 的 spring）；自己发的 0.3
            UIView.animate(springDuration: duration, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.collectionView.contentOffset.y = target
            } completion: { [weak self] _ in
                // 半路被谁改了内容高度的话，落地补一刀
                guard let self, Date() >= keyboardAnimatingUntil else { return }
                clampIfOverscrolled()
            }
        } else {
            collectionView.contentOffset.y = target
        }
    }

    /// 收藏夹跳转：那条居中
    ///
    /// 2026-09-24 她报：收藏夹跳过去「到同一页但要往下滑好一段」。行高是自量的，没画过的行只有估计值——
    /// 一次 scrollToItem 按估计值算好位置，那一片的行一画出来量出真高，目标就被挤走了。
    /// 现在不带动画连跳几次（每次用刚量出来的真高重算），直到位置不再动；
    /// 再等一拍（cell 里的 SwiftUI 有时下一帧才定高）补一次。
    func jump(to id: Int, animated: Bool) {
        guard let index = rows.firstIndex(of: .message(id)) else { return }
        let target = IndexPath(item: index, section: 0)
        settle(on: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.rows.indices.contains(index), self.rows[index] == .message(id) else { return }
            self.settle(on: target)
        }
    }

    private func settle(on target: IndexPath) {
        var last = CGFloat.nan
        for _ in 0..<6 {
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: target, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            let y = collectionView.contentOffset.y
            if abs(y - last) < 1 { break }
            last = y
        }
    }

    func selectionModeChanged(selecting: Bool, firstSelected: Int?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if selecting, let target = firstSelected {
                jump(to: target, animated: true)
            } else {
                scrollToBottom(animated: true)
            }
        }
    }

    // MARK: 自测采样（-chatSelfTest）

    private var sampler: CADisplayLink?
    private var sampleStart: CFTimeInterval = 0
    private var sampleLabel = ""
    private var sampleSeconds: Double = 0
    private var lastSampledOffset: CGFloat = .nan

    /// 逐帧记：列表的（呈现层）偏移、底栏顶边、最后一行底边在屏幕上的位置、两者间距。
    /// 键盘那一笔要是同步的，gap 从头到尾都该是同一个数。
    func startSampling(label: String, seconds: Double) {
        sampler?.invalidate()
        sampleLabel = label
        sampleSeconds = seconds
        sampleStart = CACurrentMediaTime()
        lastSampledOffset = .nan
        let link = CADisplayLink(target: self, selector: #selector(sampleTick(_:)))
        link.add(to: .main, forMode: .common)
        sampler = link
    }

    @objc private func sampleTick(_ link: CADisplayLink) {
        let t = link.timestamp - sampleStart
        let barTop = barHost.view.layer.presentation()?.frame.minY ?? barHost.view.frame.minY
        let offsetY = collectionView.layer.presentation()?.bounds.origin.y ?? collectionView.contentOffset.y
        var lastBottom: CGFloat = .nan
        if let last = rows.indices.last,
           let frame = stackLayout.layoutAttributesForItem(at: IndexPath(item: last, section: 0))?.frame {
            lastBottom = frame.maxY - offsetY
        }
        let gap = barTop - lastBottom
        let delta = lastSampledOffset.isNaN ? 0 : offsetY - lastSampledOffset
        lastSampledOffset = offsetY
        NSLog("[selftest] sample %@ t:%.0f off:%.1f d:%.1f barTop:%.1f lastBottom:%.1f gap:%.1f",
              sampleLabel, t * 1000, offsetY, delta, barTop, lastBottom, gap)
        if t > sampleSeconds {
            link.invalidate()
            sampler = nil
        }
    }

    func logState(label: String, anchor: Int?) {
        var anchorText = ""
        if let anchor, let index = rows.firstIndex(of: .message(anchor)),
           let frame = stackLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            anchorText = String(format: " anchorTop:%.1f (insetTop:%.1f)", frame.minY - collectionView.contentOffset.y, collectionView.contentInset.top)
        }
        NSLog("[selftest] state %@ off:%.1f max:%.1f overhang:%.1f content:%.1f box:%.1f inset:%.1f/%.1f bar:%.1f@%.1f kb:%.1f rows:%d%@",
              label, collectionView.contentOffset.y, maxOffsetY, overhang, collectionView.contentSize.height,
              collectionView.bounds.height, collectionView.contentInset.top, collectionView.contentInset.bottom,
              barHeight, barHost.view.frame.minY, keyboardHeight, rows.count, anchorText)
    }

    /// 某一行画出来的实际高度跟量的不一样（异步内容到了）：改高度、重排，贴着底就跟着贴
    private func rowRendered(_ row: ChatRow, height: CGFloat) {
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let rounded = ceil(height * scale) / scale
        guard rounded > 0, let known = heights[row], abs(known - rounded) > 0.5, rows.contains(row) else { return }
        log("row height drift \(row) \(known) -> \(rounded)")
        heights[row] = rounded
        renderedHeights[row] = (rowKeys[row] ?? 0, rounded)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wasNearBottom = self.isNearBottom
            self.stackLayout.heights = self.rows.map { self.heights[$0] ?? 0 }
            self.stackLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
            if wasNearBottom, Date() >= self.keyboardAnimatingUntil { self.collectionView.contentOffset.y = self.maxOffsetY }
        }
    }

    // MARK: 量高

    private func remeasureAll() {
        heights.removeAll(keepingCapacity: true)
        renderedHeights.removeAll(keepingCapacity: true)
        measuredWidth = collectionView.bounds.width
        measureMissing()
        stackLayout.heights = rows.map { heights[$0] ?? 0 }
        stackLayout.invalidateLayout()
    }

    private func measureMissing() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        measuredWidth = width
        for row in rows where heights[row] == nil {
            heights[row] = measure(row, width: width)
        }
    }

    private func measure(_ row: ChatRow, width: CGFloat) -> CGFloat {
        if let rendered = renderedHeights[row], rendered.key == rowKeys[row] {
            return rendered.height
        }
        sizingView.configuration = hostingConfiguration(for: row, measuring: true)
        sizingView.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        var height = sizingView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if height <= 0 {
            height = sizingView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
        }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let rounded = ceil(max(height, 1) * scale) / scale
        log("measure \(row) w:\(width) -> \(rounded)")
        return rounded
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard Self.verbose, indexPath.item < rows.count else { return }
        log("display \(rows[indexPath.item]) frame:\(cell.frame.height)")
    }
}
