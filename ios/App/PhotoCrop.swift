import PhotosUI
import SwiftUI

// MARK: - 导入照片时自己框（10-04 Tilia：照片小组件导进来直接变长了，要导入时能自己选怎么剪）
//
// 用法：`.photoImport(isPresented: $picking, aspect: 宽/高) { 剪好的图 in … }`
// 先弹系统相册，选完进全屏的框：两指缩放、一指拖，框里的就是剪下来的。

struct CropJob: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct PhotoImport: ViewModifier {
    @Binding var isPresented: Bool
    let aspect: CGFloat
    let onDone: (UIImage) -> Void
    @State private var item: PhotosPickerItem?
    @State private var job: CropJob?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images)
            .onChange(of: item) { _, it in
                guard let it else { return }
                Task {
                    if let data = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        job = CropJob(image: img.scaledDown(maxSide: 2400))
                    }
                    item = nil
                }
            }
            .fullScreenCover(item: $job) { j in
                PhotoCropView(image: j.image, aspect: aspect) { out in
                    job = nil
                    if let out { onDone(out) }
                }
            }
    }
}

extension View {
    /// 选一张照片 → 自己框 → 拿到剪好的图（aspect = 宽 / 高）
    func photoImport(isPresented: Binding<Bool>, aspect: CGFloat, onDone: @escaping (UIImage) -> Void) -> some View {
        modifier(PhotoImport(isPresented: isPresented, aspect: max(0.2, min(5, aspect)), onDone: onDone))
    }
}

/// 全屏黑底，中间一个框；图在框后面能拖能缩放，框外压暗
struct PhotoCropView: View {
    @EnvironmentObject private var theme: AppTheme
    let image: UIImage
    let aspect: CGFloat
    var corner: CGFloat = 22
    let onDone: (UIImage?) -> Void

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let box = cropBox(in: geo.size)
            let shown = shownSize(box)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .position(x: box.midX + offset.width, y: box.midY + offset.height)
                CropDim(hole: box, corner: corner)
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
                // 提示贴着框上沿放（放屏幕顶上会被灵动岛挡住）
                Text("拖动、两指缩放，框里的就是最后的样子")
                    .font(Typo.sans(Typo.Size.caption))
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: box.midX, y: box.minY - 26)
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack {
                        Button("取消") { onDone(nil) }
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button { onDone(render(box)) } label: {
                            Text("完成").fontWeight(.semibold).foregroundStyle(.white)
                                .padding(.horizontal, 22).padding(.vertical, 10)
                                .background(Capsule().fill(theme.accent))
                        }
                    }
                    .font(Typo.sans(Typo.Size.body))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        offset = clamp(CGSize(width: baseOffset.width + v.translation.width,
                                              height: baseOffset.height + v.translation.height), box: box)
                    }
                    .onEnded { _ in baseOffset = offset }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { v in
                            scale = max(1, min(6, baseScale * v.magnification))
                            offset = clamp(offset, box: box)
                        }
                        .onEnded { _ in
                            baseScale = scale
                            baseOffset = offset
                        })
            )
        }
        .statusBarHidden()
    }

    /// 框：屏宽减两边留白，太高的话按高度收
    private func cropBox(in size: CGSize) -> CGRect {
        var w = size.width - 48
        var h = w / aspect
        let maxH = size.height * 0.62
        if h > maxH { h = maxH; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2 - 10, width: w, height: h)
    }

    /// 图现在显示多大（刚好盖满框 × 手指缩放）
    private func shownSize(_ box: CGRect) -> CGSize {
        let s = image.size
        let fill = max(box.width / s.width, box.height / s.height) * scale
        return CGSize(width: s.width * fill, height: s.height * fill)
    }

    /// 不让图拖出框，框里永远是满的
    private func clamp(_ o: CGSize, box: CGRect) -> CGSize {
        let shown = shownSize(box)
        let mx = max(0, (shown.width - box.width) / 2), my = max(0, (shown.height - box.height) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    /// 把框里那块画出来（长边最多 1400 像素）
    private func render(_ box: CGRect) -> UIImage {
        let shown = shownSize(box)
        let k = min(1400 / max(box.width, box.height), image.size.width / shown.width * image.scale)
        let out = CGSize(width: (box.width * k).rounded(), height: (box.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: out, format: fmt).image { _ in
            let origin = CGPoint(x: (box.width - shown.width) / 2 + offset.width, y: (box.height - shown.height) / 2 + offset.height)
            image.draw(in: CGRect(x: origin.x * k, y: origin.y * k, width: shown.width * k, height: shown.height * k))
        }
    }
}

/// 整屏挖掉中间一个圆角框
private struct CropDim: Shape {
    let hole: CGRect
    let corner: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -400, dy: -400))
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: corner, height: corner), style: .continuous)
        return p
    }
}
