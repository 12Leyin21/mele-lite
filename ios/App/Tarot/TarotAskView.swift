import SwiftUI

// MARK: - 抽牌页（移植自之前自用的 App SpreadAskView，我们自己写的）
//
// 进来扇形就躺在那儿 → 写问题、挑谁来解 → 「洗牌」：牌收成一叠等 TA 的手，打圈搓、松手才洗（两秒半没碰就自己洗）；
// TA 的指尖轨迹发给服务器混进种子 → 两排扇形摊开 → 手指压着找一张、再点凸起的那张确认 → 飞到牌位翻面。
// 「帮我抽」= 从洗好的那副牌顶上发。手机只记「第几张」，牌是什么由服务器存着的牌序定。

struct TarotAskView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let spread: TarotSpreadDTO
    /// 选谁来解（追问时不显示——还是原来那位）
    var choosesReader = true
    /// 抽满之后交给外面存（新局 / 追问各自处理）；返回 false = 失败，页面退回可重试
    let commit: @MainActor (_ question: String, _ deckID: Int, _ picks: [Int], _ mode: String, _ reader: UUID?) async -> Bool

    @AppStorage("tarotDark") private var tarotDark = true
    private var style: TarotStyle { TarotStyle(dark: tarotDark) }

    enum Phase { case idle, shuffling, picking, saving }
    @State private var phase: Phase = .idle
    @State private var question = ""
    @State private var reader: UUID?
    @State private var readerPicked = false
    @State private var deck: TarotDeckDTO?
    /// 0 摊开 · 1 收成一叠等 TA 搓 · 2 / 4 自动洗时左右错开 · 3 自动洗时收拢 · 5 洗完了等服务器发牌
    @State private var shuffleStep = 0
    /// 手搓洗牌：每张牌被手指推开的位移和转角
    @State private var smear: [CGSize] = Array(repeating: .zero, count: 78)
    @State private var spin: [Double] = Array(repeating: 0, count: 78)
    @State private var smearing = false
    @State private var pileTouched = false
    @State private var lastSmear: CGPoint?
    /// TA 搓牌的轨迹，发给服务器混进种子
    @State private var trail = ""
    /// 已抽的牌在 deck 里的下标；顺序 = 牌位顺序
    @State private var taken: [Int] = []
    @State private var lifted: Int?
    @State private var flipped: Set<Int> = []
    @State private var touchStart: CGPoint?
    @State private var confirmCandidate = false
    @State private var failedText: String?
    @State private var autoDrawing = false
    /// 用过「帮我抽」（autoDrawing 发完就落回 false，存档时要知道这一局是怎么抽的）
    @State private var usedAuto = false
    @Namespace private var fly
    @FocusState private var editing: Bool

    private static let deckSize = 78
    private var remaining: [Int] { (0..<Self.deckSize).filter { !taken.contains($0) } }
    private var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            TarotBackground(dark: tarotDark)
            GeometryReader { geo in
                VStack(spacing: 12) {
                    header
                    // 打字的时候键盘占掉半屏，牌位和扇形先让开，问题框贴着标题
                    if !(phase == .idle && editing) {
                        board.frame(height: spread.boardHeight).frame(maxWidth: .infinity)
                        fan.frame(maxWidth: .infinity).frame(minHeight: 215, maxHeight: .infinity)
                    }
                    footer
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .animation(.easeInOut(duration: 0.25), value: editing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 14)
        }
        .onTapGesture { editing = false }
        .onAppear {
            guard !readerPicked else { return }
            readerPicked = true
            reader = (model.chat.flatMap { model.companion($0.companion.id) } ?? model.recentCompanion ?? model.companions.first)?.id
        }
    }

    // MARK: 头

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.inkDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(phase == .saving)
            Spacer()
            Text(spread.name).font(Fonts.serif(17, .semibold)).foregroundStyle(style.ink)
            Spacer()
            // 占位要连高一起定：不定高会把整行撑成弹簧，标题被顶到屏幕中间
            Color.clear.frame(width: 17, height: 17)
        }
    }

    // MARK: 牌位区（示意图长成真牌位，抽到的牌飞进来翻面）

    private var board: some View {
        GeometryReader { geo in
            let w = spread.cardWidth
            let h = w * 1.62
            ZStack {
                ForEach(0..<spread.count, id: \.self) { slot in
                    let p = spread.point(slot)
                    let pt = CGPoint(x: p.x * geo.size.width, y: p.y * geo.size.height)
                    let sideways = spread.key == "celtic" && slot == 1
                    if slot < taken.count, let deck {
                        TarotFlipCard(angle: flipped.contains(slot) ? 180 : 0, card: pickedCard(slot: slot, deck: deck), width: w)
                            .matchedGeometryEffect(id: taken[slot], in: fly)
                            .rotationEffect(.degrees(sideways ? 90 : 0))
                            .position(pt)
                            .zIndex(sideways ? 2 : 1)
                    } else {
                        RoundedRectangle(cornerRadius: w * 0.09, style: .continuous)
                            .strokeBorder(style.diagramStroke.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .background(RoundedRectangle(cornerRadius: w * 0.09, style: .continuous)
                                .fill(style.diagramFill.opacity(0.6)))
                            .frame(width: w, height: h)
                            .rotationEffect(.degrees(sideways ? 90 : 0))
                            .position(pt)
                    }
                    if spread.count <= 7 {
                        Text(spread.positions[slot])
                            .font(.system(size: spread.count == 1 ? 11 : 8.5))
                            .foregroundStyle(slot < taken.count ? style.inkDim : style.inkFaint)
                            .position(x: pt.x, y: pt.y + h / 2 + 9)
                            .zIndex(3)
                    }
                }
            }
        }
    }

    private func pickedCard(slot: Int, deck: TarotDeckDTO) -> TarotCardDTO {
        let d = deck.deck[taken[slot]]
        return TarotCardDTO(position: spread.positions[slot], card: d.card, reversed: d.reversed)
    }

    // MARK: 扇形

    private var fan: some View {
        GeometryReader { geo in
            let g = FanGeometry(size: geo.size, count: remaining.count)
            ZStack {
                ForEach(Array(remaining.enumerated()), id: \.element) { k, idx in
                    let isLifted = lifted == idx
                    let pose = cardPose(k: k, idx: idx, geometry: g)
                    TarotCardBack(width: FanGeometry.cardWidth, glow: isLifted,
                                  shadowed: shuffleStep == 0 || idx >= Self.deckSize - 4)
                        .matchedGeometryEffect(id: idx, in: fly)
                        .rotationEffect(.degrees(pose.rotation))
                        .position(pose.center)
                        .zIndex(isLifted ? 200 : g.stackOrder(k: k))
                        .opacity(phase == .idle ? 0.72 : 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in touchMoved(v, geometry: g) }
                    .onEnded { _ in touchEnded() }
            )
            .allowsHitTesting((phase == .picking && !autoDrawing) || (phase == .shuffling && shuffleStep == 1))
        }
        .animation(.spring(duration: 0.22), value: lifted)
    }

    private func cardPose(k: Int, idx: Int, geometry g: FanGeometry) -> (center: CGPoint, rotation: Double) {
        switch shuffleStep {
        case 1, 3, 5:
            // 收成一叠（只留一点点参差，像真的一摞牌）+ TA 搓开的位移
            let jitter = Double(idx % 5 - 2) * 0.7
            return (CGPoint(x: g.size.width / 2 + smear[idx].width, y: g.stackY + smear[idx].height), jitter + spin[idx])
        case 2, 4:
            let side: CGFloat = (idx % 2 == 0) == (shuffleStep == 2) ? -1 : 1
            let jitter = Double(idx % 7 - 3) * 1.4
            return (CGPoint(x: g.size.width / 2 + side * 44, y: g.stackY + CGFloat(idx % 3) * 1.5), jitter + Double(side) * 5)
        default:
            let angle = g.angle(k: k)
            var c = g.center(k: k)
            if lifted == idx {
                let rad = angle * .pi / 180
                c.x += FanGeometry.lift * CGFloat(sin(rad))
                c.y -= FanGeometry.lift * CGFloat(cos(rad))
            }
            return (c, angle)
        }
    }

    private func touchMoved(_ v: DragGesture.Value, geometry g: FanGeometry) {
        if phase == .shuffling {
            guard shuffleStep == 1 else { return }
            smearTouch(v.location, geometry: g)
            return
        }
        guard phase == .picking else { return }
        if touchStart == nil {
            touchStart = v.startLocation
            if let l = lifted, let k = remaining.firstIndex(of: l),
               g.hits(point: v.startLocation, cardAt: cardPose(k: k, idx: l, geometry: g)) {
                confirmCandidate = true
                return
            }
            confirmCandidate = false
        }
        if confirmCandidate {
            let d = hypot(v.location.x - (touchStart?.x ?? 0), v.location.y - (touchStart?.y ?? 0))
            if d < 14 { return }
            confirmCandidate = false
        }
        guard let k = g.nearest(to: v.location) else { return }
        let idx = remaining[k]
        if idx != lifted {
            lifted = idx
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func touchEnded() {
        if phase == .shuffling {
            guard smearing else { return }
            smearing = false
            lastSmear = nil
            Task { await finishShuffle() }
            return
        }
        if confirmCandidate, let l = lifted { confirm(l) }
        touchStart = nil
        confirmCandidate = false
    }

    /// 斗地主搓牌那种：每张牌「重量」不一样——上面的跟手走得多、底下的少；手前面的被推开、后面的拖着走；
    /// 再给每张一点固定的偏向，几圈下来就散成一桌。轨迹顺手记下来，松手时发给服务器洗。
    private func smearTouch(_ p: CGPoint, geometry g: FanGeometry) {
        pileTouched = true
        smearing = true
        let prev = lastSmear ?? p
        lastSmear = p
        let d = CGSize(width: p.x - prev.x, height: p.y - prev.y)
        let mag = hypot(d.width, d.height)
        guard mag >= 0.4 else { return }
        let dir = CGSize(width: d.width / mag, height: d.height / mag)
        let pile = CGPoint(x: g.size.width / 2, y: g.stackY)
        let reach: CGFloat = 96
        let xLimit = g.size.width / 2 - 30
        for idx in 0..<Self.deckSize {
            let c = CGPoint(x: pile.x + smear[idx].width, y: pile.y + smear[idx].height)
            let rel = CGSize(width: c.x - p.x, height: c.y - p.y)
            let dist = hypot(rel.width, rel.height)
            guard dist < reach else { continue }
            let near = 1 - dist / reach
            let depth = 0.45 + 0.65 * pow(CGFloat(idx) / CGFloat(Self.deckSize - 1), 1.3)
            let temper = 0.55 + 0.45 * CGFloat((idx * 37 + 11) % 23) / 22
            let ahead = dist < 1 ? 0 : (rel.width * dir.width + rel.height * dir.height) / dist
            let push = 0.7 + 0.5 * ahead
            let w = min((0.3 + 0.7 * near) * depth * temper * push, 1.3)
            let side = CGFloat((idx * 13) % 7 - 3) / 3 * 0.35 * near
            var o = smear[idx]
            o.width += d.width * w - d.height * side
            o.height += d.height * w + d.width * side
            o.width = min(max(o.width, -xLimit), xLimit)
            o.height = min(max(o.height, -(g.stackY - 46)), g.size.height - g.stackY - 46)
            smear[idx] = o
            let turn = Double(d.width * 0.4 - d.height * 0.25) * Double(near * temper) * (idx % 3 == 0 ? -1 : 1)
            spin[idx] = min(max(spin[idx] + turn, -55), 55)
        }
        if trail.count < 3000 { trail += "\(Int(p.x)),\(Int(p.y));" }
    }

    // MARK: 脚

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .idle:
            VStack(spacing: 12) {
                Text(spread.usage)
                    .font(.system(size: 12)).foregroundStyle(style.inkDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                if choosesReader { readerRow }
                TarotGlass(style: style, padding: 14) {
                    TextField("", text: $question, prompt: Text("心里的问题……").foregroundStyle(style.inkFaint), axis: .vertical)
                        .font(Fonts.body(15))
                        .foregroundStyle(style.ink)
                        .lineLimit(2...5)
                        .focused($editing)
                }
                if let failedText {
                    Text(failedText).font(.system(size: 12)).foregroundStyle(style.reversedTone)
                }
                Button {
                    editing = false
                    Task { await start() }
                } label: {
                    Text("洗牌").font(Fonts.body(16, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(theme.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(trimmedQuestion.isEmpty)
                .opacity(trimmedQuestion.isEmpty ? 0.5 : 1)
            }
        case .shuffling:
            VStack(spacing: 10) {
                questionLine
                Text(shuffleStep == 1
                     ? (smearing ? String(localized: "搓着呢…松手就洗好了")
                                 : String(localized: "手指在牌上打圈搓一搓，松手就洗好了 · 不碰它就自己洗"))
                     : String(localized: "洗牌中…"))
                    .font(.system(size: 12)).foregroundStyle(style.inkDim)
                    .multilineTextAlignment(.center)
            }
            .frame(minHeight: 96)
        case .picking:
            VStack(spacing: 10) {
                questionLine
                let left = spread.count - taken.count
                Text(lifted == nil ? String(localized: "手指压在牌上找一张，再点它确认") : String(localized: "点凸起来的那张确认"))
                    .font(.system(size: 12)).foregroundStyle(style.inkDim)
                HStack {
                    Text(left > 0 ? String(localized: "还差 \(left) 张") : String(localized: "抽齐了"))
                        .font(.system(size: 11)).foregroundStyle(style.inkFaint)
                    Spacer()
                    if !autoDrawing && left > 0 {
                        Button { Task { await autoDraw() } } label: {
                            Text("帮我抽")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(style.inkDim)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(style.chipFill))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let failedText {
                    HStack(spacing: 10) {
                        Text(failedText).font(.system(size: 12)).foregroundStyle(style.reversedTone)
                        Button("再试一次") { Task { await finish() } }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.accentSoft)
                    }
                }
            }
            .frame(minHeight: 96)
        case .saving:
            VStack(spacing: 10) {
                questionLine
                HStack(spacing: 8) {
                    ProgressView().tint(style.inkFaint).scaleEffect(0.8)
                    Text("存好，递过去…").font(.system(size: 12)).foregroundStyle(style.inkDim)
                }
            }
            .frame(minHeight: 96)
        }
    }

    /// 谁来解：联系人头像一排，最后一个是解牌人（中立：不带人设、不带记忆）
    private var readerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(model.companions) { c in
                    readerChip(selected: reader == c.id, title: c.name) {
                        CompanionAvatar(companion: c, size: 38)
                    } action: { reader = c.id }
                }
                readerChip(selected: reader == nil, title: String(localized: "解牌人")) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(style.ink)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(style.chipFill))
                } action: { reader = nil }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)      // 选中那圈描边往外扩了 3pt，留够边别被裁
        }
        .frame(maxWidth: .infinity)
    }

    private func readerChip<Icon: View>(selected: Bool, title: String, @ViewBuilder icon: () -> Icon,
                                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon()
                    .overlay(Circle().stroke(selected ? theme.accentSoft : .clear, lineWidth: 2).padding(-3))
                    .opacity(selected ? 1 : 0.55)
                Text(title).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? style.ink : style.inkFaint)
                    .lineLimit(1)
            }
            .frame(minWidth: 46)
        }
        .buttonStyle(.plain)
    }

    private var questionLine: some View {
        Text("「\(trimmedQuestion)」")
            .font(Fonts.serif(14)).foregroundStyle(style.ink)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: 流程

    /// 按「洗牌」：先收成一叠，等 TA 的手。搓了 → 松手时洗；两秒半没碰 → 自己洗。
    private func start() async {
        guard phase == .idle, !trimmedQuestion.isEmpty else { return }
        failedText = nil
        trail = ""
        pileTouched = false
        smearing = false
        smear = Array(repeating: .zero, count: Self.deckSize)
        spin = Array(repeating: 0, count: Self.deckSize)
        phase = .shuffling
        withAnimation(.easeInOut(duration: 0.36)) { shuffleStep = 1 }
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        guard phase == .shuffling, !pileTouched else { return }
        await autoShuffle()
    }

    /// 错开 → 收拢 → 反向错开 → 收拢，然后去服务器要牌
    private func autoShuffle() async {
        let steps: [(Int, Double)] = [(2, 0.26), (3, 0.26), (4, 0.26), (3, 0.26)]
        for (step, dur) in steps {
            withAnimation(.easeInOut(duration: dur)) { shuffleStep = step }
            if step == 2 || step == 4 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000) + 40_000_000)
        }
        await finishShuffle()
    }

    /// 洗完了：先收成一叠（搓散的牌归拢），同时把轨迹发去服务器拿这副牌，牌到了再摊开
    private func finishShuffle() async {
        guard phase == .shuffling, shuffleStep != 5 else { return }
        let scattered = pileTouched
        withAnimation(.spring(duration: 0.45, bounce: 0.05)) {
            shuffleStep = 5
            smear = Array(repeating: .zero, count: Self.deckSize)
            spin = Array(repeating: 0, count: Self.deckSize)
        }
        let api = model.api
        let t = trail
        async let fetched = try? TarotAPI.deck(api, trail: t)
        if scattered {
            try? await Task.sleep(nanoseconds: 520_000_000)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        guard let d = await fetched else {
            failedText = String(localized: "洗牌没洗成（网络？），再按一次")
            withAnimation(.easeInOut(duration: 0.4)) { shuffleStep = 0 }
            phase = .idle
            return
        }
        deck = d
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(duration: 0.6, bounce: 0.12)) { shuffleStep = 0 }
        phase = .picking
    }

    private func confirm(_ idx: Int) {
        guard phase == .picking, taken.count < spread.count, !taken.contains(idx) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(duration: 0.55, bounce: 0.15)) {
            taken.append(idx)
            lifted = nil
        }
        let slot = taken.count - 1
        Task {
            try? await Task.sleep(nanoseconds: 520_000_000)
            withAnimation(.easeInOut(duration: 0.45)) { _ = flipped.insert(slot) }
            if taken.count == spread.count {
                try? await Task.sleep(nanoseconds: 750_000_000)
                await finish()
            }
        }
    }

    /// 从这副牌顶上按张数发——同一副牌，只是不想一张张摸的时候
    private func autoDraw() async {
        guard phase == .picking, !autoDrawing else { return }
        autoDrawing = true
        usedAuto = true
        lifted = nil
        while taken.count < spread.count, phase == .picking, let next = remaining.first {
            confirm(next)
            try? await Task.sleep(nanoseconds: 420_000_000)
        }
        autoDrawing = false
    }

    private func finish() async {
        guard phase == .picking, taken.count == spread.count, let deck else { return }
        phase = .saving
        failedText = nil
        let ok = await commit(trimmedQuestion, deck.deckID, taken, usedAuto ? "auto" : "hand", reader)
        if ok {
            dismiss()
        } else {
            failedText = String(localized: "没存上")
            phase = .picking
        }
    }
}
