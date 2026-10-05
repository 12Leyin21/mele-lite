import SwiftUI

// MARK: - 牌局页（移植自之前自用的 App TarotReadingPage）
//
// 日期 + 牌阵 → 所问 → 牌（下面正逆位 + 关键词小标签）→ 解读（还没写好时「正在看牌…」，轮询长出来）
// → 追问块 → 「再问一张」（TA 问的局、主解读写好、上一个追问也解完了才出现；还是原来那位来解）。
// 解失败了（服务器试了三次）给「再解一次」。

struct TarotReadingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss

    @AppStorage("tarotDark") private var tarotDark = true
    private var style: TarotStyle { TarotStyle(dark: tarotDark) }

    @State private var reading: TarotReadingDTO
    @State private var askingFollowup = false
    @State private var retrying = false

    init(reading: TarotReadingDTO) {
        _reading = State(initialValue: reading)
    }

    private var readerName: String { TarotReader.name(reading.reader, in: model.companions) }

    var body: some View {
        ZStack {
            TarotBackground(dark: tarotDark)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    questionCard
                    cardsArea
                    interpretationBlock
                    ForEach(Array(reading.followups.enumerated()), id: \.offset) { index, item in
                        followupBlock(index: index, item: item)
                    }
                    followupButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 80)
            }
        }
        .task(id: reading.followups.count) { await poll() }
        .fullScreenCover(isPresented: $askingFollowup) {
            TarotAskView(spread: .followup, choosesReader: false) { q, deck, picks, mode, _ in
                guard let pick = picks.first,
                      let r = try? await TarotAPI.followup(model.api, id: reading.id, deck: deck, pick: pick, question: q, mode: mode)
                else { return false }
                withAnimation { reading = r }
                return true
            }
            .environmentObject(model).environmentObject(theme)
        }
    }

    /// 解读还没来时守着（页面关掉就停）：主解读或最后一个追问，哪个在等就守哪个
    private func poll() async {
        for _ in 0..<90 {
            guard reading.isWaiting || reading.followupWaiting else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            if let r = try? await TarotAPI.one(model.api, id: reading.id), r != reading {
                withAnimation { reading = r }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style.inkDim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.bottom, 6)
            Text("READING").font(.system(size: 11, weight: .medium)).tracking(4).foregroundStyle(style.inkFaint)
            HStack(spacing: 10) {
                Text(TarotWhen.dateOnly(reading.createdAt)).font(Fonts.serif(28, .semibold)).foregroundStyle(style.ink)
                Text(reading.spreadName)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(theme.accent.opacity(style.dark ? 0.28 : 0.18)))
                    .foregroundStyle(style.dark ? theme.accentSoft : theme.accent)
            }
        }
    }

    private var questionCard: some View {
        TarotGlass(style: style, padding: 15) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reading.asker == "contact" ? String(localized: "\(readerName) 问的") : String(localized: "所问"))
                    .font(.system(size: 10.5, weight: .medium)).tracking(2).foregroundStyle(style.inkFaint)
                Text(reading.question).font(Fonts.serif(17)).foregroundStyle(style.ink).lineSpacing(4)
            }
        }
    }

    @ViewBuilder
    private var cardsArea: some View {
        if reading.cards.count == 1, let card = reading.cards.first {
            VStack(spacing: 14) {
                TarotCardFace(card: card, width: 200)
                caption(card)
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(reading.cards.enumerated()), id: \.offset) { _, card in
                        VStack(spacing: 8) {
                            Text(card.position).font(.system(size: 10.5)).foregroundStyle(style.inkDim)
                            TarotCardFace(card: card, width: 118)
                            caption(card, compact: true)
                        }
                        .frame(width: 138)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
    }

    private func caption(_ card: TarotCardDTO, compact: Bool = false) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text(card.name)
                    .font(Fonts.serif(compact ? 14 : 17, .semibold)).foregroundStyle(style.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(card.reversed ? String(localized: "逆位") : String(localized: "正位"))
                    .font(.system(size: compact ? 9.5 : 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(card.reversed ? style.reversedTone.opacity(0.20)
                                                             : theme.accent.opacity(style.dark ? 0.26 : 0.16)))
                    .foregroundStyle(card.reversed ? style.reversedTone : (style.dark ? theme.accentSoft : theme.accent))
            }
            if !card.keywords.isEmpty {
                // 多牌横排时格子窄，只放前两个词，别挤成省略号
                TarotChips(words: compact ? Array(card.keywords.prefix(2)) : card.keywords, style: style, compact: compact)
            }
        }
    }

    private var interpretationBlock: some View {
        TarotGlass(style: style, padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text(reading.asker == "contact" ? String(localized: "\(readerName) 的心里话")
                                                : String(localized: "\(readerName) 解读"))
                    .font(.system(size: 10.5, weight: .medium)).tracking(2).foregroundStyle(style.inkFaint)
                waitingOr(text: reading.interpretation, status: reading.status, waiting: String(localized: "正在看牌…"))
            }
        }
    }

    @ViewBuilder
    private func waitingOr(text: String, status: String, waiting: String) -> some View {
        if status == "failed" {
            HStack(spacing: 10) {
                Text("这一局没解成").font(.system(size: 13)).foregroundStyle(style.reversedTone)
                Button {
                    Task {
                        retrying = true
                        if let r = try? await TarotAPI.retry(model.api, id: reading.id) { withAnimation { reading = r } }
                        retrying = false
                    }
                } label: {
                    Text("再解一次").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accentSoft)
                }
                .buttonStyle(.plain)
                .disabled(retrying)
            }
            .padding(.vertical, 4)
        } else if text.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(style.inkFaint).scaleEffect(0.8)
                Text(waiting).font(.system(size: 13)).foregroundStyle(style.inkDim)
            }
            .padding(.vertical, 6)
        } else {
            Text(text)
                .font(Fonts.body(14.5)).foregroundStyle(style.ink)
                .lineSpacing(6)
                .textSelection(.enabled)
        }
    }

    private func followupBlock(index: Int, item: TarotFollowupDTO) -> some View {
        TarotGlass(style: style, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("追问 \(index + 1)").font(.system(size: 10.5, weight: .medium)).tracking(2).foregroundStyle(style.inkFaint)
                Text(item.question).font(Fonts.serif(16)).foregroundStyle(style.ink).lineSpacing(4)
                VStack(spacing: 12) {
                    TarotCardFace(card: item.card, width: 132)
                    caption(item.card)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                waitingOr(text: item.interpretation, status: item.status, waiting: String(localized: "正在看这一张…"))
            }
        }
    }

    @ViewBuilder
    private var followupButton: some View {
        if reading.asker == "user", reading.status == "done", !reading.interpretation.isEmpty,
           !reading.followupWaiting, reading.followups.last?.status != "failed" {
            Button { askingFollowup = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text("再问一张")
                }
                .font(Fonts.body(14, .medium))
                .foregroundStyle(style.inkDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous)
                    .strokeBorder(style.diagramStroke.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .buttonStyle(.plain)
        }
    }
}
