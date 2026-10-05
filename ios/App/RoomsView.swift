import SwiftUI

/// Library / Memory 两个标签（09-29 Tilia：照之前自用的 App分法，顺序 Home / Library / Memory / Me）。
/// 先是朴素的房间格子，一格一个房间；UI Tilia之后统一整理。
struct Room: Identifiable {
    let id: String
    let title: String
    let icon: String            // SF Symbols
    var needsHost = false        // Lite 里灰着（要 Mele Host）
    let open: () -> Void

    init(id: String, title: String, icon: String, needsHost: Bool = false, open: @escaping () -> Void) {
        self.id = id; self.title = title; self.icon = icon; self.needsHost = needsHost; self.open = open
    }
}

struct RoomsGrid: View {
    @EnvironmentObject private var theme: AppTheme
    let title: String
    let rooms: [Room]

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(Typo.accent(Typo.Size.largeTitle))
                    .foregroundStyle(theme.ink)
                    .titleBar()
                    .padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(rooms) { r in
                        Button(action: r.open) {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: r.icon)
                                    .font(Typo.icon(22))
                                    .foregroundStyle(theme.accentDeep)
                                Spacer(minLength: 0)
                                Text(r.title)
                                    .font(Typo.sans(Typo.Size.headline, .semibold))
                                    .foregroundStyle(theme.ink)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                            .cardSurface()
                        }
                        .buttonStyle(.plain)
                        .modifier(RoomGate(needsHost: r.needsHost))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }
}

/// 要 Mele Host 的房间：Lite 里灰着，角上一把小锁
private struct RoomGate: ViewModifier {
    let needsHost: Bool
    func body(content: Content) -> some View {
        if needsHost { content.needsHost(note: false).overlay(alignment: .topTrailing) {
            if Lite.local { Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary).padding(14) }
        } } else { content }
    }
}

extension Notification.Name {
    /// 开饮食页（Library 的格子、以后的小组件都走它）
    static let lumiOpenFood = Notification.Name("LumiOpenFood")
}

struct LibraryView: View {
    var body: some View {
        RoomsGrid(title: "Library", rooms: [
            Room(id: "food", title: String(localized: "饮食"), icon: "fork.knife") {
                NotificationCenter.default.post(name: .lumiOpenFood, object: nil)
            },
            Room(id: "music", title: String(localized: "音乐"), icon: "music.note") {
                NotificationCenter.default.post(name: .lumiOpenMusic, object: nil)
            },
            Room(id: "lore", title: String(localized: "世界书"), icon: "book.closed") {
                NotificationCenter.default.post(name: .lumiOpenLore, object: nil)
            },
            Room(id: "people", title: String(localized: "人物卡"), icon: "person.crop.rectangle.stack") {
                NotificationCenter.default.post(name: .lumiOpenPeople, object: nil)
            },
            Room(id: "todo", title: String(localized: "待办"), icon: "checklist") {
                NotificationCenter.default.post(name: .lumiOpenTodo, object: nil)
            },
            Room(id: "stickers", title: String(localized: "表情包"), icon: "face.smiling") {
                NotificationCenter.default.post(name: .lumiOpenStickers, object: nil)
            },
            Room(id: "wallet", title: String(localized: "钱包"), icon: "wallet.pass") {
                NotificationCenter.default.post(name: .lumiOpenWallet, object: nil)
            },
            Room(id: "books", title: String(localized: "书架"), icon: "books.vertical") {
                NotificationCenter.default.post(name: .lumiOpenBooks, object: nil)
            },
            Room(id: "tarot", title: String(localized: "塔罗"), icon: "moon.stars") {
                NotificationCenter.default.post(name: .lumiOpenTarot, object: nil)
            },
            Room(id: "calendar", title: String(localized: "日历"), icon: "calendar") {
                NotificationCenter.default.post(name: .lumiOpenCalendar, object: nil)
            },
            Room(id: "moments", title: String(localized: "朋友圈"), icon: "camera.aperture") {
                NotificationCenter.default.post(name: .lumiOpenMoments, object: nil)
            },
        ])
    }
}

