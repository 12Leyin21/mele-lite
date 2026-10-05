import SwiftUI

/// 档案袋（Record）：点洞洞板上的档案袋半升起来（照之前自用的 App GroupHallView 的 recordHall，10-04 Tilia要的）。
/// 顶上一片梯形封舌写着 Record，下面一沓索引卡：收藏夹 / 里程碑 / 通话历史 / 人物卡，卡角压一样东西。
struct RecordHall: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var milestones: [MilestoneDTO] = []
    @State private var showMilestones = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            ZStack(alignment: .top) {
                TrapezoidFlap()
                    .frame(height: 96)
                    .ignoresSafeArea(edges: .top)
                VStack(spacing: 10) {
                    Text("Record")
                        .font(.custom("Ballet", size: 34))
                        .foregroundStyle(theme.accentDeep.opacity(0.85))
                        .padding(.top, 30)
                        .padding(.bottom, 16)
                    IndexCard(tab: String(localized: "收藏夹"), tabSlot: 0,
                              line: favorites.items.isEmpty ? String(localized: "长按聊天里的消息收藏")
                                                            : String(localized: "存了 \(favorites.items.count) 条舍不得删的"),
                              tilt: -1.2, art: { cardArt(LocketArt(), height: 58, tilt: -8) }) { go(.lumiOpenFavorites) }
                    IndexCard(tab: String(localized: "里程碑"), tabSlot: 1,
                              line: String(localized: "我们的大事记 · 已立 \(milestones.count) 座"),
                              tilt: 0.8, art: { cardArt(StarButtonArt(), height: 40, tilt: 12) }) { showMilestones = true }
                    IndexCard(tab: String(localized: "通话历史"), tabSlot: 2,
                              line: String(localized: "还没通过话"),
                              tilt: -0.6, art: { cardArt(RotaryPhoneArt(), height: 50, tilt: -4) }) {}
                    IndexCard(tab: String(localized: "人物卡"), tabSlot: 1,
                              line: String(localized: "TA 老记不住的人 · 一提起就递给 TA"),
                              tilt: 0.9, art: { cardArt(GuestCheckArt(), height: 62, tilt: 9) }) { go(.lumiOpenPeople) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            await favorites.load(model.api)
            milestones = (try? await model.api.call("GET", "milestones")) ?? []
        }
        .sheet(isPresented: $showMilestones) {
            MilestonesList(items: milestones).environmentObject(model).environmentObject(theme)
                .presentationDetents([.medium, .large])
        }
    }

    /// 关掉档案袋再开房间（房间是 Tab 那层的全屏页，叠在半升的页上开不出来）
    private func go(_ name: Notification.Name) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: name, object: nil) }
    }

    /// 卡角压的那样东西（代码画的，10-04）
    private func cardArt<V: View>(_ art: V, height: CGFloat, tilt: Double) -> some View {
        art
            .frame(height: height)
            .rotationEffect(.degrees(tilt))
            .shadow(color: .black.opacity(0.18), radius: 2.5, y: 2)
            .padding(.trailing, 14).padding(.bottom, 6)
    }
}

struct MilestoneDTO: Decodable, Identifiable {
    let id: Int
    let companionID: String
    let title: String
    let at: Date
    enum CodingKeys: String, CodingKey { case id, title, at; case companionID = "companion_id" }
}

/// 里程碑：它在聊天里觉得值得记住就立一座
struct MilestonesList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let items: [MilestoneDTO]

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("聊着聊着，TA 觉得值得记住的时刻，会在这里立一座。")
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .listRowBackground(Color.clear)
                }
                ForEach(items.sorted { $0.at > $1.at }) { m in
                    HStack(spacing: 12) {
                        Image(systemName: "star.fill").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                            Text("\(model.companions.first { $0.id.uuidString.lowercased() == m.companionID }?.name ?? "") · \(m.at.formatted(date: .abbreviated, time: .omitted))")
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                    }
                }
            }
            .navigationTitle("里程碑")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.colorScheme, .light)
    }
}

/// 一张索引卡（照之前自用的 App）：顶上一枚主题色纸标签（梯形，0/1/2 = 左/中/右错开），卡面米白纸 + 一行小字，右下角压一样东西
struct IndexCard<Art: View>: View {
    @EnvironmentObject var theme: AppTheme
    let tab: String
    let tabSlot: Int
    let line: String
    var tilt: Double = 0
    @ViewBuilder var art: () -> Art
    let action: () -> Void

    struct TabShape: Shape {
        func path(in r: CGRect) -> Path {
            let inset: CGFloat = 10, rad: CGFloat = 5
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + inset - 1.5, y: r.minY + rad))
            p.addQuadCurve(to: CGPoint(x: r.minX + inset + rad, y: r.minY), control: CGPoint(x: r.minX + inset, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - inset - rad, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - inset + 1.5, y: r.minY + rad), control: CGPoint(x: r.maxX - inset, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    if tabSlot > 0 { Spacer(minLength: 0) }
                    Text(tab)
                        .font(Typo.sans(14, .semibold))
                        .foregroundStyle(theme.ink.opacity(0.72))
                        .padding(.horizontal, 24).padding(.top, 7).padding(.bottom, 8)
                        .background(TabShape().fill(Color(hue: theme.hue / 360, saturation: 0.16, brightness: 0.97)))
                    if tabSlot < 2 { Spacer(minLength: 0) }
                }
                .padding(.horizontal, tabSlot == 1 ? 0 : 14)
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(red: 0.995, green: 0.985, blue: 0.965))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                    VStack(spacing: 18) {
                        Rectangle().fill(theme.accent.opacity(0.14)).frame(height: 0.7)
                        Rectangle().fill(theme.accent.opacity(0.14)).frame(height: 0.7)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    Text(line)
                        .font(Typo.sans(14))
                        .foregroundStyle(theme.ink.opacity(0.6))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 18).padding(.trailing, 90).padding(.top, 16)
                    art()
                }
                .frame(height: 78)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(red: 0.995, green: 0.985, blue: 0.965))
                        .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 5)
                }
            }
            .rotationEffect(.degrees(tilt))
            .contentShape(Rectangle())
        }
        .buttonStyle(IndexCardPress())
    }
}

private struct IndexCardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? -4 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 档案袋的梯形封舌：顶边整宽，两边往里斜，底边窄，底角圆
struct TrapezoidFlap: View {
    struct Shape_: Shape {
        func path(in r: CGRect) -> Path {
            let inset = r.width * 0.16, rad: CGFloat = 10
            var p = Path()
            p.move(to: CGPoint(x: r.minX - 2, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX + 2, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - inset + rad * 0.4, y: r.maxY - rad))
            p.addQuadCurve(to: CGPoint(x: r.maxX - inset - rad, y: r.maxY), control: CGPoint(x: r.maxX - inset, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + inset + rad, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX + inset - rad * 0.4, y: r.maxY - rad), control: CGPoint(x: r.minX + inset, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        Shape_()
            .fill(LinearGradient(colors: [Color(red: 0.975, green: 0.968, blue: 0.955), Color(red: 0.935, green: 0.928, blue: 0.915)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Shape_().stroke(Color.white.opacity(0.8), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 4)
    }
}
