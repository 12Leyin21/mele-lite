import SwiftUI

/// 它申请翻你的手机（Lite，10-04 Tilia：什么都能给看，但得先在聊天里申请）。
/// 申请不做成卡片（Tilia 10-04）：它一发起，屏幕中间弹出来、背后模糊（PeekPrompt）；聊天里只留一行灰字（PeekNoticeRow）。
/// kind「peek:ask」= 还没答；「peek:ok:diary,wallet」= 给看了哪几间；「peek:no」= 没给。
enum PeekKind {
    static func state(_ kind: String) -> String { kind.split(separator: ":").dropFirst().first.map(String.init) ?? "ask" }
    static func rooms(_ kind: String) -> [String] {
        let bits = kind.split(separator: ":", maxSplits: 2)
        return bits.count == 3 ? bits[2].split(separator: ",").map(String.init) : []
    }
}

/// 聊天里那一行灰字（像系统提示，居中）
struct PeekNoticeRow: View {
    let kind: String
    let companionName: String
    let skin: ChatSkin

    private var line: String {
        switch PeekKind.state(kind) {
        case "ok":
            let rs = PeekKind.rooms(kind)
            if rs.isEmpty || rs.count == PeekRoomName.all.count { return String(localized: "你把手机递给了\(companionName)") }
            let names = rs.map(PeekRoomName.name)
            return names.count <= 3 ? String(localized: "你给\(companionName)看了\(names.joined(separator: "、"))")
                : String(localized: "你给\(companionName)看了\(names.prefix(3).joined(separator: "、"))等 \(names.count) 样")
        case "no": return String(localized: "你没把手机给\(companionName)")
        default: return String(localized: "\(companionName)想看看你的手机")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "iphone").font(Typo.icon(10))
            Text(line).font(Typo.sans(skin.size(Typo.Size.caption)))
        }
        .foregroundStyle(skin.inkFaint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// 屏幕中间那一块：背后整屏模糊；先问「给不给」，点「给看」翻成勾哪几间
struct PeekPrompt: View {
    @EnvironmentObject private var theme: AppTheme
    let companionName: String
    let want: String
    let avatar: UIImage?
    let onAnswer: (_ allow: Bool, _ rooms: [String]) -> Void

    @State private var choosing = false
    @State private var picked = Set(PeekRoomName.all)
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .overlay(Color.black.opacity(0.18).ignoresSafeArea())
            VStack(spacing: 14) {
                Group {
                    if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                    else {
                        LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Text(String(companionName.prefix(1))).font(Typo.sans(22, .semibold)).foregroundStyle(.white))
                    }
                }
                .frame(width: 58, height: 58).clipShape(Circle())
                Text("\(companionName)想看看你的手机")
                    .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                if !want.isEmpty {
                    Text("「\(want)」").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if choosing { roomGrid }
                HStack(spacing: 10) {
                    Button { choosing ? withAnimation(.snappy) { choosing = false } : onAnswer(false, []) } label: {
                        Text(choosing ? "返回" : "不给").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(Color.white.opacity(0.75)))
                    }
                    Button {
                        if choosing { onAnswer(true, PeekRoomName.all.filter(picked.contains)) }
                        else { withAnimation(.snappy) { choosing = true } }
                    } label: {
                        Text(choosing ? "递给\(companionName)" : "给看").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(theme.accentDeep))
                    }
                    .disabled(choosing && picked.isEmpty)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white.opacity(0.92)))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 10)
            .padding(.horizontal, 24)
            .scaleEffect(shown ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
        }
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { shown = true } }
    }

    private var roomGrid: some View {
        VStack(spacing: 8) {
            Text("跟\(companionName)自己的聊天、小号的聊天、私密日记不会给。")
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).multilineTextAlignment(.center)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(PeekRoomName.all, id: \.self) { id in
                    let on = picked.contains(id)
                    Button { if on { picked.remove(id) } else { picked.insert(id) } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: PeekRoomName.icon(id)).font(Typo.icon(14))
                            Text(PeekRoomName.name(id)).font(Typo.sans(Typo.Size.caption, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(on ? theme.accentDeep : theme.inkFaint)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(on ? theme.accentSoft.opacity(0.35) : Color.black.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

enum PeekRoomName {
    /// 跟 Lite/LocalPeek.rooms 同一个顺序
    static let all = ["chats", "diary", "wallet", "food", "album", "todos", "moments", "favorites", "books", "music", "lore", "stickers"]

    static func name(_ id: String) -> String {
        switch id {
        case "chats": String(localized: "跟别人的聊天")
        case "diary": String(localized: "日记")
        case "wallet": String(localized: "钱包")
        case "food": String(localized: "饮食")
        case "album": String(localized: "相册")
        case "todos": String(localized: "待办")
        case "moments": String(localized: "朋友圈")
        case "favorites": String(localized: "收藏")
        case "books": String(localized: "书架")
        case "music": String(localized: "歌")
        case "lore": String(localized: "世界书")
        case "stickers": String(localized: "表情包")
        default: id
        }
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "chats": "bubble.left.and.bubble.right"
        case "diary": "book.pages"
        case "wallet": "wallet.pass"
        case "food": "fork.knife"
        case "album": "photo.on.rectangle"
        case "todos": "checklist"
        case "moments": "camera.aperture"
        case "favorites": "star"
        case "books": "books.vertical"
        case "music": "music.note"
        case "lore": "book.closed"
        default: "face.smiling"
        }
    }
}

/// 它提议陪你专注（10-05 Tilia：跟查手机一样弹在中间，不往聊天里挂卡）：offer = 「复习期末 · 120 分钟」
struct FocusPrompt: View {
    @EnvironmentObject private var theme: AppTheme
    let companionName: String
    let offer: String
    let avatar: UIImage?
    let onAnswer: (_ start: Bool) -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .overlay(Color.black.opacity(0.18).ignoresSafeArea())
                .onTapGesture { onAnswer(false) }
            VStack(spacing: 14) {
                Group {
                    if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                    else {
                        LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Text(String(companionName.prefix(1))).font(Typo.sans(22, .semibold)).foregroundStyle(.white))
                    }
                }
                .frame(width: 58, height: 58).clipShape(Circle())
                Text("\(companionName)想陪你专注一会儿")
                    .font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                if !offer.isEmpty {
                    Text(offer).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { onAnswer(false) } label: {
                        Text("先不了").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.inkDim)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(Color.white.opacity(0.75)))
                    }
                    Button { onAnswer(true) } label: {
                        Text("开始专注").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(theme.accentDeep))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white.opacity(0.92)))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 10)
            .padding(.horizontal, 24)
            .scaleEffect(shown ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
        }
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { shown = true } }
    }
}
