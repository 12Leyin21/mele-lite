import SwiftUI
import CryptoKit

/// 带登录凭证取图片并缓存（聊天里的图片附件用）。从之前自用的 App搬来：两级缓存，内存 NSCache + 磁盘 Caches/auth-images
/// （重启不用重下）。urlPath 在 Lumi 里是接口路径 `attachments/<编号>`，取图走 APIClient（带 Bearer）。
struct AuthImageView: View {
    let urlPath: String
    var contentMode: ContentMode = .fill   // 气泡缩略图裁满；全屏查看传 .fit 完整显示
    /// 差不多方的图（宽高比 0.8~1.25）裁成正方形，明显长方形的照旧按比例
    var squareIfNearSquare = false
    @State private var image: UIImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, UIImage>()
    /// 取图用的接口（SessionStore 起来时塞进来）
    nonisolated(unsafe) static var api: APIClient?

    /// 上传成功的那一刻把本地这张图先塞进缓存（之前自用的 App 09-01「照片好久才加载出来」）：
    /// 刚上传完的图不用再从服务器下载一遍。key 跟气泡里用的路径一字不差。
    static func seed(urlPath: String, data: Data) {
        guard !urlPath.isEmpty, let image = UIImage(data: data) else { return }
        cache.setObject(image, forKey: urlPath as NSString)
        writeDisk(urlPath: urlPath, data: data)
    }

    /// 提前把一张图拉进缓存
    static func prefetch(urlPath: String) {
        guard !urlPath.isEmpty, cache.object(forKey: urlPath as NSString) == nil else { return }
        if let disk = readDisk(urlPath: urlPath) {
            cache.setObject(disk, forKey: urlPath as NSString)
            return
        }
        Task.detached(priority: .utility) {
            guard let (data, image) = await fetch(urlPath: urlPath) else { return }
            cache.setObject(image, forKey: urlPath as NSString)
            writeDisk(urlPath: urlPath, data: data)
        }
    }

    /// 拿到这张图本身（全屏查看用）
    static func image(urlPath: String) async -> UIImage? {
        if let cached = cache.object(forKey: urlPath as NSString) { return cached }
        if let disk = readDisk(urlPath: urlPath) {
            cache.setObject(disk, forKey: urlPath as NSString)
            return disk
        }
        guard let (data, loaded) = await fetch(urlPath: urlPath) else { return nil }
        cache.setObject(loaded, forKey: urlPath as NSString)
        writeDisk(urlPath: urlPath, data: data)
        return loaded
    }

    // MARK: 网络 + 磁盘

    static func fetch(urlPath: String) async -> (Data, UIImage)? {
        guard let api, let data = try? await api.data(urlPath), let image = UIImage(data: data) else { return nil }
        return (data, image)
    }

    private static var diskDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("auth-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func diskFile(urlPath: String) -> URL {
        let digest = SHA256.hash(data: Data(urlPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest)
    }

    private static func readDisk(urlPath: String) -> UIImage? {
        guard let data = try? Data(contentsOf: diskFile(urlPath: urlPath)) else { return nil }
        return UIImage(data: data)
    }

    private static func writeDisk(urlPath: String, data: Data) {
        try? data.write(to: diskFile(urlPath: urlPath), options: .atomic)
    }

    var body: some View {
        Group {
            if let image, squareIfNearSquare,
               (0.8...1.25).contains(image.size.width / max(image.size.height, 1)) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(Image(uiImage: image).resizable().scaledToFill())
                    .clipped()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Color.white.opacity(0.3)
                    .overlay(Image(systemName: "photo")
                        .font(Typo.icon(22)).foregroundStyle(AppTheme.inkFaint))
            } else {
                Color.white.opacity(0.3)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: urlPath) { await load() }
    }

    private func load() async {
        failed = false   // 换了一张（urlPath 变了）就别卡在上一张的「没下成」上
        if let cached = Self.cache.object(forKey: urlPath as NSString) {
            image = cached
            return
        }
        if let disk = Self.readDisk(urlPath: urlPath) {
            Self.cache.setObject(disk, forKey: urlPath as NSString)
            image = disk
            return
        }
        guard let (data, loaded) = await Self.fetch(urlPath: urlPath) else {
            failed = true
            return
        }
        Self.cache.setObject(loaded, forKey: urlPath as NSString)
        Self.writeDisk(urlPath: urlPath, data: data)
        image = loaded
    }
}

extension UIImage {
    /// 发送前把大图缩到合理尺寸，省流量省服务器空间
    func resizedIfNeeded(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

/// 全屏看图（之前自用的 App 07-24）：多图消息点开后左右滑切换、双击/捏合缩放、下滑或点 ✕ 关闭
struct ImageViewerState: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

struct ImageViewerView: View {
    let state: ImageViewerState
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int

    init(state: ImageViewerState) {
        self.state = state
        _page = State(initialValue: state.index)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PagedZoomViewer(urls: state.urls, page: $page) { dismiss() }
                .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(Typo.icon(15, .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                if state.urls.count > 1 {
                    Text("\(page + 1) / \(state.urls.count)")
                        .font(Typo.sans(Typo.Size.callout))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.trailing, 6)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }
}

/// 看图的翻页 + 缩放（之前自用的 App 09-25：放大之后也要能滑着换照片）。
/// SwiftUI 的 TabView 里套手势会把翻页吞了，所以是 UIKit 的老办法（跟系统相册一个做法）：外层横向翻页的 UIScrollView，每页一个能缩放的
/// UIScrollView。放大了先在图里拖，拖到边再往外就翻到下一张——两层滚动系统自己交接。
/// 没放大时往下拉 90pt 关掉；双击 2 倍 / 还原。
private struct PagedZoomViewer: UIViewRepresentable {
    let urls: [String]
    @Binding var page: Int
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PagerScrollView {
        let pager = PagerScrollView()
        pager.onLayout = { [weak coordinator = context.coordinator, weak pager] in
            if let coordinator, let pager { coordinator.layout(pager) }
        }
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.backgroundColor = .clear
        pager.delegate = context.coordinator
        for url in urls {
            let zp = ZoomPage(urlPath: url)
            zp.onPullDown = { onDismiss() }
            pager.addSubview(zp)
            context.coordinator.pages.append(zp)
        }
        return pager
    }

    func updateUIView(_ pager: PagerScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.layout(pager)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PagedZoomViewer
        var pages: [ZoomPage] = []
        private var lastSize: CGSize = .zero
        init(_ parent: PagedZoomViewer) { self.parent = parent }

        /// 尺寸变了（第一次摆、转屏）重排每页，停在当前页
        func layout(_ pager: UIScrollView) {
            let size = pager.bounds.size
            guard size.width > 0, size != lastSize else { return }
            lastSize = size
            for (i, zp) in pages.enumerated() {
                zp.frame = CGRect(x: CGFloat(i) * size.width, y: 0, width: size.width, height: size.height)
                zp.relayout()
            }
            pager.contentSize = CGSize(width: size.width * CGFloat(pages.count), height: size.height)
            pager.contentOffset = CGPoint(x: CGFloat(parent.page) * size.width, y: 0)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            let w = max(scrollView.bounds.width, 1)
            let p = Int((scrollView.contentOffset.x / w).rounded())
            guard p != parent.page else { return }
            // 翻走的那张还原，回来时是整张
            if pages.indices.contains(parent.page) { pages[parent.page].setZoomScale(1, animated: false) }
            parent.page = p
        }
    }
}

/// 外层翻页：自己量到尺寸时通知重排（updateUIView 那会儿还是 0×0）
final class PagerScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// 一页：能缩放的图
final class ZoomPage: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    var onPullDown: (() -> Void)?

    init(urlPath: String) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true            // 没放大时也能往下拉，拉够了关
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        spinner.color = .white
        spinner.startAnimating()
        addSubview(spinner)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
        Task { @MainActor [weak self] in
            let img = await AuthImageView.image(urlPath: urlPath)
            guard let self else { return }
            self.spinner.stopAnimating()
            self.spinner.isHidden = true
            self.imageView.image = img ?? UIImage(systemName: "photo")
            self.imageView.tintColor = .gray
            self.relayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 图按原比例放进这一页，居中
    func relayout() {
        setZoomScale(1, animated: false)
        let b = bounds.size
        spinner.center = CGPoint(x: b.width / 2, y: b.height / 2)
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0, b.width > 0 else {
            imageView.frame = CGRect(origin: .zero, size: b)
            return
        }
        let s = min(b.width / img.size.width, b.height / img.size.height)
        let fit = CGSize(width: img.size.width * s, height: img.size.height * s)
        imageView.frame = CGRect(origin: .zero, size: fit)
        contentSize = fit
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    /// 图比页面小的那一边，用 inset 把它挪到正中
    private func center() {
        let b = bounds.size, c = imageView.frame.size
        contentInset = UIEdgeInsets(top: max(0, (b.height - c.height) / 2), left: max(0, (b.width - c.width) / 2),
                                    bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // 没放大、往下拉过 90pt → 关
        if zoomScale <= 1.01, contentOffset.y + contentInset.top < -90 { onPullDown?() }
    }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            let w = bounds.width / 2, h = bounds.height / 2
            zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
