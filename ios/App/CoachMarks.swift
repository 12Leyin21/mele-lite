import SwiftUI

// MARK: - 功能导览（第二块第 12 步，Tilia 09-28）
//
// 一次亮一个按钮、其余糊掉，旁边一句话说它能干嘛；点一下下一个，右下角「跳过」。
// 按钮用 .coachMark("名字") 报自己在屏幕上的位置；页面拿 CoachOverlay 按顺序放。看过记本机，不再出现。

struct CoachFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func coachMark(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: CoachFrameKey.self, value: [id: g.frame(in: .global)])
        })
    }

    @ViewBuilder func coachMark(_ id: String, when on: Bool) -> some View {
        if on { coachMark(id) } else { self }
    }
}

struct CoachStep: Identifiable, Equatable {
    let id: String          // 对应 .coachMark 的名字
    let text: String
    var padding: CGFloat = 8
}

/// 导览要不要放：onboarding 做完就把两段都记成「待看」；Me 里能重看
enum CoachTour {
    static let chatKey = "tourChatPending"
    static let homeKey = "tourHomePending"
    static func arm() {
        UserDefaults.standard.set(true, forKey: chatKey)
        UserDefaults.standard.set(true, forKey: homeKey)
    }
    static func pending(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func done(_ key: String) { UserDefaults.standard.set(false, forKey: key) }
}

struct CoachOverlay: View {
    @EnvironmentObject private var theme: AppTheme
    let steps: [CoachStep]
    let frames: [String: CGRect]
    let onFinish: () -> Void
    @State private var index = 0

    private var step: CoachStep? { index < steps.count ? steps[index] : nil }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let hole = step.flatMap { frames[$0.id] }.map {
                $0.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -(step?.padding ?? 8), dy: -(step?.padding ?? 8))
            }
            ZStack {
                // 糊掉其余的：毛玻璃 + 一层暗，挖一个洞露出这一步的按钮
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.28))
                }
                .mask {
                    ZStack {
                        Rectangle()
                        if let hole {
                            RoundedRectangle(cornerRadius: min(22, hole.height / 2), style: .continuous)
                                .frame(width: hole.width, height: hole.height)
                                .position(x: hole.midX, y: hole.midY)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { next() }

                if let hole, let step {
                    let below = hole.midY < geo.size.height * 0.55
                    Text(step.text)
                        .font(Typo.sans(Typo.Size.body, .medium))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous).fill(.regularMaterial))
                        .frame(maxWidth: 280)
                        .position(x: min(max(hole.midX, 150), geo.size.width - 150),
                                  y: below ? hole.maxY + 50 : hole.minY - 50)
                        .allowsHitTesting(false)
                        .id(step.id)
                        .transition(.opacity)
                }

                // 圈的东西在下半屏（比如 Dock 上的星星）：跳过挪到上面，别压着它（10-10）
                let low = hole.map { $0.midY > geo.size.height * 0.6 } ?? false
                VStack {
                    if !low { Spacer() }
                    HStack(spacing: 12) {
                        Spacer()
                        Text("\(index + 1) / \(steps.count)").font(Typo.number(Typo.Size.caption, .regular))
                            .foregroundStyle(.white.opacity(0.8))
                        Button("跳过") { onFinish() }
                            .font(Typo.sans(Typo.Size.body, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.35)))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, low ? 0 : 44)
                    .padding(.top, low ? 70 : 0)
                    if low { Spacer() }
                }
            }
            .animation(.snappy(duration: 0.3), value: index)
        }
        // 整块铺满屏幕（含刘海和底部横条），这样坐标跟按钮报上来的全局坐标是同一套
        .ignoresSafeArea()
        .onAppear { skipMissing() }
    }

    private func next() {
        index += 1
        skipMissing()
    }

    /// 这一步的按钮屏幕上没有（比如只读回顾页）就跳过
    private func skipMissing() {
        while let s = step, frames[s.id] == nil { index += 1 }
        if step == nil { onFinish() }
    }
}
