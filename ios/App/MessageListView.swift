import PhotosUI
import UniformTypeIdentifiers
import SwiftUI

/// 消息列表（第二块第 9 步）：一行一个联系人，点进这个人最近的窗口。
/// 不止一个窗口时行尾「N ⌵」，点开往下列出每个窗口（长按改名 / 删）；左滑置顶 / 删除；右上「＋」加联系人。
struct MessageListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    var onBack: () -> Void

    @State private var expanded: Set<UUID> = []
    @State private var adding = false
    @State private var renaming: (CompanionDTO, ConversationDTO)?
    @State private var renameDraft = ""
    @State private var deletingWindow: (CompanionDTO, ConversationDTO)?
    @State private var deletingCompanion: CompanionDTO?
    @AppStorage("notOnlyLumiSeen") private var notOnlyLumiSeen = false
    /// Lite：建小号 / 用小号加好友（10-04）
    @State private var creatingAlt = false
    @State private var addingFriend = false
    @State private var friendAlt: AltDTO?
    @State private var managingAlts = false
    @State private var deletingAltWindow: (CompanionDTO, ConversationDTO)?
    /// 现在是小号：Messages 整页换成它加的好友
    private var altNow: AltDTO? { model.activeAlt.flatMap { id in model.alts.first { $0.id == id } } }

    var body: some View {
        ZStack {
            AppBackground()
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
                if let alt = altNow {
                    altSection(alt)
                } else {
                    mainSection
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $managingAlts) {
            AltManagerSheet(onNew: { creatingAlt = true })
                .environmentObject(model).environmentObject(theme)
                .environment(\.colorScheme, .light)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("删掉这段对话？", isPresented: Binding(get: { deletingAltWindow != nil }, set: { if !$0 { deletingAltWindow = nil } }),
                            titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let (c, conv) = deletingAltWindow { Task { await model.deleteConversation(c, conv) } }
                deletingAltWindow = nil
            }
        } message: {
            Text("跟\(deletingAltWindow?.0.name ?? "TA")的这段聊天会删掉，好友也一起删（以后能再加）。")
        }
        .sheet(isPresented: $creatingAlt) {
            AltIdentitySheet { made in model.activeAlt = made.id; friendAlt = made; addingFriend = true }
                .environmentObject(model).environmentObject(theme)
                .environment(\.colorScheme, .light)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $addingFriend, onDismiss: { friendAlt = nil }) {
            AddFriendSheet(preselected: friendAlt) { creatingAlt = true }
                .environmentObject(model).environmentObject(theme)
                .environment(\.colorScheme, .light)
                .presentationDetents([.large])
        }
        .task { await model.refreshFriends() }
        .sheet(isPresented: $adding) {
            AddCompanionView()
                .environmentObject(model).environmentObject(theme)
                .presentationDetents([.medium])
        }
        .alert("给这个窗口起个名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("空着就用第一句", text: $renameDraft)
            Button("保存") {
                if let (c, conv) = renaming { Task { await model.renameConversation(c, conv, title: renameDraft) } }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("删掉这个窗口？", isPresented: Binding(get: { deletingWindow != nil }, set: { if !$0 { deletingWindow = nil } }),
                            titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let (c, conv) = deletingWindow { Task { await model.deleteConversation(c, conv) } }
                deletingWindow = nil
            }
        } message: {
            Text("这段聊天会删掉；TA 记得的事还在。")
        }
        .confirmationDialog("删除这个联系人？", isPresented: Binding(get: { deletingCompanion != nil }, set: { if !$0 { deletingCompanion = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let c = deletingCompanion { Task { await model.deleteCompanion(c) } }
                deletingCompanion = nil
            }
        } message: {
            Text("\(deletingCompanion?.name ?? "TA")的所有聊天、TA 记得的事、设定都会一起删掉，找不回来。")
        }
    }

    // MARK: 小号：它加的好友一人一行

    @ViewBuilder private func altSection(_ alt: AltDTO) -> some View {
        ForEach(model.friendRequests.filter { $0.state == "pending" && $0.altID == alt.id }) { q in
            pendingRow(q)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
        }
        let rows = model.windows(ofAlt: alt.id)
        ForEach(rows, id: \.1.id) { c, conv in
            altRow(c, conv)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deletingAltWindow = (c, conv) } label: { Label("删除", systemImage: "trash") }
                }
                .contextMenu {
                    Button(role: .destructive) { deletingAltWindow = (c, conv) } label: { Label("删掉对话", systemImage: "trash") }
                }
        }
        if rows.isEmpty && !model.friendRequests.contains(where: { $0.state == "pending" && $0.altID == alt.id }) {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.dashed").font(Typo.icon(26)).foregroundStyle(theme.accent)
                Text("「\(alt.userName)」还没有好友").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                Button { friendAlt = alt; addingFriend = true } label: {
                    Text("加好友").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 9).background(Capsule().fill(theme.accentDeep))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func altRow(_ c: CompanionDTO, _ conv: ConversationDTO) -> some View {
        Button { model.openChat(c, conversation: conv.id) } label: {
            HStack(spacing: 12) {
                CompanionAvatar(companion: c, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(c.name).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                        Spacer()
                        Text(ChatTime.short(conv.lastAt)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                    }
                    HStack {
                        Text(conv.preview.isEmpty ? String(localized: "刚加上好友") : conv.preview)
                            .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).lineLimit(1)
                        Spacer()
                        if model.isUnread(conv) { UnreadDot() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
    }

    // MARK: 大号：联系人（带展开的窗口）

    @ViewBuilder private var mainSection: some View {
                ForEach(model.sortedCompanions) { c in
                    companionBlock(c)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if model.companions.count > 1 {
                                Button(role: .destructive) { deletingCompanion = c } label: { Label("删除", systemImage: "trash") }
                            }
                            Button { model.pinned.formSymmetricDifference([c.id]) } label: {
                                Label(model.pinned.contains(c.id) ? "取消置顶" : "置顶",
                                      systemImage: model.pinned.contains(c.id) ? "pin.slash" : "pin")
                            }
                            .tint(theme.accentDeep)
                        }
                }
                if showNotOnlyLumi {
                    notOnlyLumi
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 5, trailing: 20))
                }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(Typo.icon(17, .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 0) {
                Text("Messages")
                    .font(Typo.accent(Typo.Size.title))
                    .foregroundStyle(theme.ink)
                if let alt = altNow {
                    Text("小号 · \(alt.userName)").font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.accentDeep)
                }
            }
            Spacer()
            if Lite.local {
                // 人头：小号管理（新建 / 删 / 切换），10-04 Tilia
                Button { managingAlts = true } label: {
                    Image(systemName: altNow == nil ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(Typo.icon(18, .semibold))
                        .foregroundStyle(altNow == nil ? theme.ink : theme.accentDeep)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            // 别的身份那边有没看的
                            if otherIdentityUnread {
                                UnreadDot().offset(x: -4, y: 9)
                            }
                        }
                }
                .buttonStyle(.plain)
                // 右上角 ＋：加联系人 / 加好友（小号下直接用这个小号加）
                Menu {
                    Button { adding = true } label: { Label("加联系人", systemImage: "person.badge.plus") }
                    Button { friendAlt = altNow; addingFriend = true } label: { Label("加好友", systemImage: "magnifyingglass") }
                } label: { plusIcon }
            } else {
                Button { adding = true } label: { plusIcon }
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, -12)
        .padding(.trailing, -10)
        .padding(.top, 6)
    }

    /// 别的身份（大号 / 别的小号）那边有没看的
    private var otherIdentityUnread: Bool {
        guard let me = altNow else { return model.altHasUnread() }
        return model.companions.contains { model.hasUnread($0.id) } || model.alts.contains { $0.id != me.id && model.altHasUnread($0.id) }
    }

    private var plusIcon: some View {
        Image(systemName: "plus")
            .font(Typo.icon(17, .semibold))
            .foregroundStyle(theme.ink)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// 发出去还没通过的好友申请
    private func pendingRow(_ q: FriendRequestDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass").font(Typo.icon(15)).foregroundStyle(theme.accentDeep)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("「\(q.altName)」申请加\(q.name)").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                Text("等对方通过").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .cardSurface()
    }

    // MARK: 一个联系人（带展开的窗口）

    private func companionBlock(_ c: CompanionDTO) -> some View {
        let convs = model.conversations[c.id] ?? []
        let open = expanded.contains(c.id)
        return VStack(spacing: 0) {
            companionRow(c, windows: convs.count, open: open)
                .contextMenu {
                    Button { model.settingsFor = c } label: { Label("TA 的设定", systemImage: "slider.horizontal.3") }
                }
            if open && convs.count > 1 {
                ForEach(convs) { conv in
                    Divider().padding(.leading, 76)
                    windowRow(c, conv)
                }
            }
        }
        .cardSurface()
    }

    private func companionRow(_ c: CompanionDTO, windows: Int, open: Bool) -> some View {
        HStack(spacing: 12) {
            Button { Task { await model.openChat(c) } } label: {
                HStack(spacing: 12) {
                    CompanionAvatar(companion: c, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(c.name).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                            if model.pinned.contains(c.id) {
                                Image(systemName: "pin.fill").font(Typo.icon(10)).foregroundStyle(theme.inkFaint)
                            }
                            Spacer()
                            if let at = model.lastAt(c.id) {
                                Text(ChatTime.short(at)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                            }
                        }
                        HStack {
                            Text(model.preview(c.id))
                                .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).lineLimit(1)
                            Spacer()
                            if model.hasUnread(c.id) { UnreadDot() }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if windows > 1 {
                Button {
                    withAnimation(.snappy) { expanded.formSymmetricDifference([c.id]) }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(windows)").font(Typo.number(Typo.Size.caption, .medium))
                        Image(systemName: "chevron.down").font(Typo.icon(10, .semibold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .foregroundStyle(theme.inkDim)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .capsuleSurface(strength: 0.6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func windowRow(_ c: CompanionDTO, _ conv: ConversationDTO) -> some View {
        Button { model.openChat(c, conversation: conv.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: conv.altName.isEmpty ? "bubble.left" : "person.crop.circle.dashed")
                    .font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
                    .frame(width: 48)
                Text(conv.displayName).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink).lineLimit(1)
                Spacer()
                if model.isUnread(conv) { UnreadDot() }
                Text(ChatTime.short(conv.lastAt)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renameDraft = conv.title; renaming = (c, conv) } label: { Label("改名", systemImage: "pencil") }
            Button(role: .destructive) { deletingWindow = (c, conv) } label: { Label("删掉", systemImage: "trash") }
        }
    }

    // MARK: 不只 Lumi

    private var showNotOnlyLumi: Bool { !notOnlyLumiSeen && model.chattedOnce && model.companions.count == 1 }

    private var notOnlyLumi: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2").font(Typo.icon(16)).foregroundStyle(theme.accentDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("不只 \(model.companions.first?.name ?? "Lumi")").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                Text("你还可以加别人：朋友、搭子，各有各的样子。").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
            }
            Spacer()
            Button { adding = true; notOnlyLumiSeen = true } label: {
                Image(systemName: "plus").font(Typo.icon(14, .semibold)).foregroundStyle(theme.accentDeep)
                    .frame(width: 34, height: 34).capsuleSurface(strength: 0.8)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardSurface()
        .overlay(alignment: .topTrailing) {
            Button { withAnimation { notOnlyLumiSeen = true } } label: {
                Image(systemName: "xmark").font(Typo.icon(10, .bold)).foregroundStyle(theme.inkFaint).padding(8)
            }
            .buttonStyle(.plain)
        }
    }
}

struct UnreadDot: View {
    @EnvironmentObject private var theme: AppTheme
    var body: some View { Circle().fill(theme.accentDeep).frame(width: 8, height: 8) }
}

/// 加联系人：名字 → 头像（可跳过）→ 进它的第一个窗口
struct AddCompanionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: PhotosPickerItem?
    @State private var avatar: UIImage?
    @State private var saving = false
    @State private var error: String?
    @State private var importing = false
    @State private var cardFile: CardFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New").font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink)
            HStack(spacing: 16) {
                PhotosPicker(selection: $picked, matching: .images) {
                    Group {
                        if let avatar {
                            Image(uiImage: avatar).resizable().scaledToFill()
                        } else {
                            LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay(Image(systemName: "camera").font(Typo.icon(18)).foregroundStyle(.white))
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("叫 TA 什么？").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    TextField("名字", text: $name)
                        .font(Typo.sans(Typo.Size.headline))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: Radii.control).fill(Color.white.opacity(0.7)))
                }
            }
            Text("头像可以先不选，之后在 TA 的设定里换。").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
            Spacer()
            Button { Task { await save() } } label: {
                Text(saving ? "…" : "开始聊").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Capsule().fill(theme.accentDeep))
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            // 导入酒馆角色卡（10-01）：PNG 卡或 JSON 卡
            Button { importing = true } label: {
                Label("导入角色卡", systemImage: "square.and.arrow.down")
                    .font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.accentDeep)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .json]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { cardFile = CardFile(data: data, name: url.lastPathComponent) }
        }
        .sheet(item: $cardFile) { f in
            CardImportView(file: f) { dismiss() }.environmentObject(model).environmentObject(theme)
        }
        .onChange(of: picked) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    avatar = img.squareCropped(to: 512)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.addCompanion(name: name.trimmingCharacters(in: .whitespaces),
                                         avatar: avatar?.jpegData(compressionQuality: 0.88))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
