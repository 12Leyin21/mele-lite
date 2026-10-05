import SwiftUI
import WidgetKit
import UIKit

/// 登录以后整个 app 共用的一份：联系人、每人的窗口、我的设定、头像、未读、往哪儿推。
/// 聊天页自己的消息归 ChatStore（一个窗口一个），这里只管「列表」那一层。
@MainActor
final class AppModel: ObservableObject {
    let api: APIClient

    @Published private(set) var companions: [CompanionDTO] = []
    @Published private(set) var conversations: [UUID: [ConversationDTO]] = [:]   // 联系人 → 窗口（新的在前）；只有大号的
    /// 小号的窗口（Lite，10-04 Tilia：不收在联系人下面，切成小号时 Messages 整页换成它们）
    @Published private(set) var altWindows: [UUID: [ConversationDTO]] = [:]
    /// 现在是哪个小号（nil = 大号），记在本机
    @Published var activeAlt: String? = UserDefaults.standard.string(forKey: "activeAlt") {
        didSet { UserDefaults.standard.set(activeAlt, forKey: "activeAlt") }
    }
    @Published private(set) var me: AccountDTO?
    @Published private(set) var profile: ProfileDTO?
    @Published private(set) var loaded = false
    @Published var loadError: String?
    @Published private(set) var avatarImages: [UUID: UIImage] = [:]
    @Published private(set) var wakes: [UUID: WakesDTO] = [:]

    // 推开的层：首页 →（消息列表）→（聊天）
    @Published var listOpen = false
    @Published var chat: ChatTarget?
    /// 「TA 的设定」开给谁（聊天页 ⋯、消息列表长按都走这里）
    @Published var settingsFor: CompanionDTO?
    /// 引导刚做完：进主页后打开 Lumi 的聊天，让它先开口
    var greetPending = false

    struct ChatTarget: Equatable, Identifiable {
        let companion: CompanionDTO
        let conversation: UUID
        var incognito = false
        /// 小号窗口：TA 在这里把你当成谁（空 = 平常的你）
        var altName = ""
        var id: UUID { conversation }
    }

    /// Lite：你的小号、好友申请（10-04）
    @Published var alts: [AltDTO] = []
    @Published var friendRequests: [FriendRequestDTO] = []
    private var friendWatch: NSObjectProtocol?

    init(api: APIClient) {
        self.api = api
        if Lite.local {
            friendWatch = NotificationCenter.default.addObserver(forName: .liteFriendAccepted, object: nil, queue: .main) { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
    }

    func refreshFriends() async {
        guard Lite.local else { return }
        alts = (try? await api.call("GET", "alts")) ?? alts
        friendRequests = (try? await api.call("GET", "friends/requests")) ?? friendRequests
        if let a = activeAlt, !alts.contains(where: { $0.id == a }) { activeAlt = nil }
    }

    /// 某个小号的窗口：一个好友一行（新的在前）
    func windows(ofAlt alt: String) -> [(CompanionDTO, ConversationDTO)] {
        companions.flatMap { c in (altWindows[c.id] ?? []).filter { $0.altID == alt }.map { (c, $0) } }
            .sorted { $0.1.lastAt > $1.1.lastAt }
    }

    /// 小号有没有没看的（人头图标上挂个点）
    func altHasUnread(_ alt: String? = nil) -> Bool {
        altWindows.values.joined().contains { (alt == nil || $0.altID == alt) && isUnread($0) }
    }

    /// 删一个小号：它加的好友、聊天一起删
    func deleteAlt(_ id: String) async {
        do {
            try await api.send("DELETE", "alts/\(id)")
            if activeAlt == id { activeAlt = nil }
            await refresh()
        } catch { loadError = error.localizedDescription }
    }

    // MARK: - 读

    func refresh() async {
        do {
            async let m: AccountDTO = api.call("GET", "me")
            async let p: ProfileDTO = api.call("GET", "me/profile")
            let list: [CompanionDTO] = try await api.call("GET", "companions")
            var convs: [UUID: [ConversationDTO]] = [:], alts: [UUID: [ConversationDTO]] = [:]
            for c in list {
                let all: [ConversationDTO] = try await api.call("GET", "companions/\(c.id.lowercased)/conversations")
                convs[c.id] = all.filter { $0.altName.isEmpty }
                alts[c.id] = all.filter { !$0.altName.isEmpty }
            }
            me = try await m
            profile = try await p
            companions = list
            conversations = convs
            altWindows = alts
            loadError = nil
            loaded = true
            for c in list { await loadAvatar(c) }
            if let c = primaryCompanion { await loadWakes(c.id, days: 3) }   // 顺带写小组件快照
            await syncTimeZone()
            await refreshFriends()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 手机换了时区（出门旅行），所有联系人的设置跟着换——几点、深夜、每天早上 5 点补额度都按它算
    func syncTimeZone() async {
        let tz = TimeZone.current.identifier
        for c in companions {
            let detail = try? await api.raw("GET", "companions/\(c.id.lowercased)") as? [String: Any]
            let cur = (detail?["settings"] as? [String: Any])?["tz"] as? String
            if cur != tz { _ = try? await api.raw("PATCH", "companions/\(c.id.lowercased)", json: ["settings": ["tz": tz]]) }
        }
    }

    /// 几点睡几点起：账号级，一次写进每个联系人
    func setSleep(from: String, to: String) async {
        for c in companions {
            _ = try? await api.raw("PATCH", "companions/\(c.id.lowercased)", json: ["settings": ["sleep_from": from, "sleep_to": to]])
        }
    }

    /// 刚加了钥匙：还在用免费额度的联系人都换上它
    func useKeyWhereFree(_ keyID: String) async {
        for c in companions where c.keyID == nil {
            _ = try? await api.raw("PATCH", "companions/\(c.id.lowercased)", json: ["key_id": keyID])
        }
        await refresh()
    }

    func refreshMe() async { me = (try? await api.call("GET", "me")) ?? me }

    func saveProfile(_ p: ProfileDTO) async throws {
        profile = try await api.call("PUT", "me/profile", json: ["name": p.name, "pronoun": p.pronoun, "looks": p.looks])
    }

    /// 联系人按最后说话的时间排（置顶的在最前，置顶记在本机）
    var sortedCompanions: [CompanionDTO] {
        companions.sorted { a, b in
            let pa = pinned.contains(a.id), pb = pinned.contains(b.id)
            if pa != pb { return pa }
            return (lastAt(a.id) ?? .distantPast) > (lastAt(b.id) ?? .distantPast)
        }
    }

    func lastAt(_ companion: UUID) -> Date? { conversations[companion]?.first?.lastAt }
    func latestConversation(_ companion: UUID) -> ConversationDTO? { conversations[companion]?.first }
    /// 列表里那一行的预览：最近一段有话的（刚开的空窗口不算）
    func preview(_ companion: UUID) -> String {
        (conversations[companion] ?? []).first { !$0.preview.isEmpty }?.preview ?? ""
    }

    /// 主聊天那个联系人（首页大卡那个；规则跟 PrimaryCard 一样，读同一个 primaryPick）
    var primaryCompanion: CompanionDTO? {
        UserDefaults.standard.string(forKey: "primaryPick") == "busiest" ? (busiestCompanion ?? recentCompanion) : recentCompanion
    }


    /// 小组件的快照（09-29）：主联系人今天来找过几次、最近一句，抽屉几封 / 几封能拆。写进 App Group，小组件只读它
    func writeWidgetSnapshot() async {
        guard let c = primaryCompanion else { return }
        let w = wakes[c.id]
        let last = w?.items.first { $0.outcome == "said" && $0.text != nil }
        let drawer: [DrawerItemDTO] = (try? await api.call("GET", "drawer")) ?? []
        let snap = WidgetSnapshot(companionName: c.name, wakesSaid: w?.today.said ?? 0,
                                  lastWakeText: last?.text.map { $0.replacingOccurrences(of: "\n\n", with: " ") },
                                  lastWakeAt: last?.at.timeIntervalSince1970,
                                  drawerCount: drawer.count, drawerReady: drawer.filter { $0.openable && !$0.opened }.count,
                                  updatedAt: Date().timeIntervalSince1970)
        guard snap.withoutTime != WidgetSnapshot.load().withoutTime else { return }   // 没变就不叫小组件重画（系统限次数）
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 最近说过话的那个联系人
    var recentCompanion: CompanionDTO? { sortedCompanionsByTime.first }
    /// 最近 7 天聊得最多的（一样多就看谁最近说过话）
    var busiestCompanion: CompanionDTO? {
        var best: CompanionDTO?
        for c in sortedCompanionsByTime where best == nil || c.weekMessages > best!.weekMessages { best = c }
        return best
    }
    private var sortedCompanionsByTime: [CompanionDTO] {
        companions.sorted { (lastAt($0.id) ?? .distantPast) > (lastAt($1.id) ?? .distantPast) }
    }

    /// 引导做完：进 Lumi 的聊天，它先打招呼（服务器只在一句话都没有时跑，已经聊过就 409，不管它）
    func greetIfPending() async {
        guard greetPending, let lumi = companions.first else { return }
        greetPending = false
        await openChat(lumi)
        try? await Task.sleep(for: .milliseconds(700))      // 让聊天页先连上事件流，招呼一个字一个字地出来
        _ = try? await api.raw("POST", "companions/\(lumi.id.lowercased)/greet")
    }

    /// 推送设备号报给服务器（换手机、重装都会变）
    func reportDevice() async {
        guard let token = PushDelegate.pendingToken else { return }
        if Lite.local { return }                                     // 手机里的小管家没有推送
        if Lite.hosted {                                             // 连着 Mele Host：经中转站（10-04 第四步）
            guard let relay = await PushRelay.register(token: token) else { return }
            try? await api.send("POST", "me/devices", json: ["apns_token": "relay:\(relay.id)", "relay_secret": relay.secret,
                                                             "push_key": PushRelay.pushKey])
            return
        }
        try? await api.send("POST", "me/devices", json: ["apns_token": token])
    }

    // MARK: - 醒来账

    func loadWakes(_ companion: UUID, days: Int = 1) async {
        if let w: WakesDTO = try? await api.call("GET", "companions/\(companion.lowercased)/wakes",
                                                 query: [URLQueryItem(name: "days", value: "\(days)")]) {
            wakes[companion] = w
            if companion == primaryCompanion?.id { await writeWidgetSnapshot() }
        }
    }

    func companion(_ id: UUID?) -> CompanionDTO? { companions.first { $0.id == id } }

    // MARK: - 头像

    private func avatarKey(_ c: CompanionDTO) -> String { "\(c.id.lowercased)-\(c.avatarVer)" }

    func loadAvatar(_ c: CompanionDTO) async {
        guard c.avatarVer > 0 else { avatarImages[c.id] = nil; return }
        let file = Self.avatarDir.appendingPathComponent(avatarKey(c) + ".jpg")
        if let img = UIImage(contentsOfFile: file.path) { avatarImages[c.id] = img; return }
        guard let data = try? await api.data("companions/\(c.id.lowercased)/avatar"), let img = UIImage(data: data) else { return }
        try? data.write(to: file)
        avatarImages[c.id] = img
    }

    private static var avatarDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 未读（记在本机：每个窗口看到的最后一条消息的时间）

    private var seen: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "lastSeen") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "lastSeen") }
    }

    func markSeen(_ conversation: UUID, at date: Date = Date()) {
        var s = seen
        s[conversation.lowercased] = date.timeIntervalSince1970
        seen = s
        objectWillChange.send()
    }

    func isUnread(_ conv: ConversationDTO) -> Bool {
        guard !conv.preview.isEmpty else { return false }
        guard let t = seen[conv.id.lowercased] else { return true }
        return conv.lastAt.timeIntervalSince1970 > t + 1
    }

    func hasUnread(_ companion: UUID) -> Bool { (conversations[companion] ?? []).contains(where: isUnread) }

    /// 聊过一次以后，消息列表底下才浮「不只 Lumi」小卡
    var chattedOnce: Bool {
        get { UserDefaults.standard.bool(forKey: "chattedOnce") }
        set { UserDefaults.standard.set(newValue, forKey: "chattedOnce"); objectWillChange.send() }
    }

    // MARK: - 置顶（本机）

    var pinned: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: "pinnedCompanions") ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "pinnedCompanions"); objectWillChange.send() }
    }

    // MARK: - 推开

    /// 进这个人最近的窗口；一个都没有就开一个
    func openChat(_ c: CompanionDTO) async {
        if let conv = latestConversation(c.id) {
            chat = ChatTarget(companion: c, conversation: conv.id, altName: conv.altName)
            return
        }
        await openNewWindow(c)
    }

    func openChat(_ c: CompanionDTO, conversation: UUID) {
        let alt = altWindows[c.id]?.first { $0.id == conversation }?.altName ?? ""
        chat = ChatTarget(companion: c, conversation: conversation, altName: alt)
    }

    /// alt = 小号（user_name / about_me / relationship），只有 Lite 的小管家认
    func openNewWindow(_ c: CompanionDTO, incognito: Bool = false, alt: [String: String]? = nil) async {
        do {
            var body: [String: Any] = incognito ? ["incognito": true] : [:]
            if let alt { body["alt"] = alt }
            let made: ConversationDTO = try await api.call("POST", "companions/\(c.id.lowercased)/conversations", json: body)
            if made.altName.isEmpty { if !incognito { conversations[c.id, default: []].insert(made, at: 0) } }
            else { altWindows[c.id, default: []].insert(made, at: 0) }
            chat = ChatTarget(companion: c, conversation: made.id, incognito: incognito, altName: made.altName)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - 改

    func renameConversation(_ c: CompanionDTO, _ conv: ConversationDTO, title: String) async {
        if let made: ConversationDTO = try? await api.call("PATCH", "conversations/\(conv.id.lowercased)", json: ["title": title]),
           let i = conversations[c.id]?.firstIndex(where: { $0.id == conv.id }) {
            conversations[c.id]?[i] = made
        }
    }

    func deleteConversation(_ c: CompanionDTO, _ conv: ConversationDTO) async {
        do {
            try await api.send("DELETE", "conversations/\(conv.id.lowercased)")
            conversations[c.id]?.removeAll { $0.id == conv.id }
            altWindows[c.id]?.removeAll { $0.id == conv.id }
            await refreshFriends()
        } catch { loadError = error.localizedDescription }
    }

    func deleteCompanion(_ c: CompanionDTO) async {
        do {
            try await api.send("DELETE", "companions/\(c.id.lowercased)")
            companions.removeAll { $0.id == c.id }
            conversations[c.id] = nil
            pinned.remove(c.id)
        } catch { loadError = error.localizedDescription }
    }

    /// 加联系人：名字 → （可选）头像 → 刷新 → 进它的第一个窗口
    func addCompanion(name: String, avatar: Data?) async throws {
        struct Made: Decodable { let id: UUID }
        let made: Made = try await api.call("POST", "companions", json: ["name": name])
        if let avatar {
            _ = try? await api.uploadAvatar(companion: made.id, data: avatar)
        }
        await refresh()
        if let c = companions.first(where: { $0.id == made.id }) { await openChat(c) }
    }

    /// 导入酒馆角色卡（10-01）：服务器建好联系人（人设、头像、世界书、开场白）→ 刷新 → 进它的第一个窗口
    func importCard(_ data: Data, fileName: String, greeting: Int, style: String) async throws {
        struct Made: Decodable { let id: UUID }
        let out = try await api.importCard(data, fileName: fileName, preview: false, greeting: greeting, style: style)
        let made = try JSONDecoder().decode(Made.self, from: out)
        await refresh()
        if let c = companions.first(where: { $0.id == made.id }) { await openChat(c) }
    }

    /// 聊天页关掉以后：记下看到这儿了，刷新一下这个人的窗口（预览、时间）
    func chatClosed(_ target: ChatTarget) async {
        if target.incognito { return }
        markSeen(target.conversation)
        chattedOnce = true
        if let convs: [ConversationDTO] = try? await api.call("GET", "companions/\(target.companion.id.lowercased)/conversations") {
            conversations[target.companion.id] = convs.filter { $0.altName.isEmpty }
            altWindows[target.companion.id] = convs.filter { !$0.altName.isEmpty }
        }
    }
}

extension UUID {
    /// 服务器路径里用小写
    var lowercased: String { uuidString.lowercased() }
}
