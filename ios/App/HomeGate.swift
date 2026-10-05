import SwiftUI

/// 聊天房间的壳：ChatStore 跟着这个窗口活（@StateObject），换窗口就换一个。
/// 名字和头像写进聊天页用的那两处（companionName、AvatarStore.ai），聊天页本身不用知道有几个联系人。
struct ChatRoom: View {
    @StateObject private var chat: ChatStore
    @EnvironmentObject private var avatars: AvatarStore
    @EnvironmentObject private var model: AppModel
    @AppStorage("companionName") private var companionName = "Lumi"
    @AppStorage("companionRelationship") private var companionRelationship = ""
    let companion: CompanionDTO
    var onBack: (() -> Void)? = nil
    var incognito = false
    var onNewWindow: (() -> Void)? = nil
    var onIncognito: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    var altName = ""

    init(companion: CompanionDTO, conversation: UUID, api: APIClient, incognito: Bool = false,
         onBack: (() -> Void)? = nil, onNewWindow: (() -> Void)? = nil, onIncognito: (() -> Void)? = nil,
         onSettings: (() -> Void)? = nil, altName: String = "") {
        self.companion = companion
        self.onBack = onBack
        self.incognito = incognito
        self.onNewWindow = onNewWindow
        self.onIncognito = onIncognito
        self.onSettings = onSettings
        self.altName = altName
        _chat = StateObject(wrappedValue: ChatStore(api: api, conversation: conversation))
    }

    var body: some View {
        ChatView(companionID: companion.id, onBack: onBack, incognito: incognito,
                 onNewWindow: onNewWindow, onIncognito: onIncognito, onSettings: onSettings,
                 altName: altName)
            .environmentObject(chat)
            .onAppear {
                companionName = companion.name
                companionRelationship = model.companion(companion.id)?.relationship ?? companion.relationship
                avatars.ai = model.avatarImages[companion.id]
                PushDelegate.openConversation = chat.conversation
                PushDelegate.clearDelivered()
            }
            .onReceive(model.$companions) { list in
                if let c = list.first(where: { $0.id == companion.id }) { companionRelationship = c.relationship }
            }
            .onDisappear {
                if PushDelegate.openConversation == chat.conversation { PushDelegate.openConversation = nil }
            }
    }
}
