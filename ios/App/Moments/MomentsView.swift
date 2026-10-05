import PhotosUI
import SwiftUI

/// 朋友圈（10-01，移植自之前自用的 App 的 MomentsView.swift）：大封面、右下角头像和名字、签名在头像下面、一条条动态、
/// 「…」弹出 赞 / 评论、底下框里是赞和评论链。点动态上谁的头像进谁的主页（它的封面、它自己写的签名、只有它发的）。
/// 背景（10-01 Tilia）：跟主页同一张壁纸，但盖一层从四边往中间漫的发亮白雾，只在中心隐约看得到壁纸。
struct MomentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: MomentsStore
    @State private var composing = false
    @State private var showActivity = false
    @State private var menuFor: Int?
    @State private var justClosed: (id: Int, at: Date)?
    @State private var deletingComment: MomentCommentDTO?
    @State private var replying: (moment: MomentDTO, to: MomentCommentDTO?)?
    @State private var draft = ""
    @State private var coverPick: PhotosPickerItem?
    @State private var askCover = false
    @State private var pickingCover = false
    @State private var viewing: ViewedPhoto?
    @State private var visiting: String?
    @State private var editingSig = false
    @State private var sigDraft = ""
    @State private var pull: CGFloat = 0
    @State private var refreshing = false
    @FocusState private var inputFocused: Bool

    static let coverHeight: CGFloat = 280
    struct ViewedPhoto: Identifiable { let id = UUID(); let urls: [String]; let index: Int }

    init(api: APIClient, who: String? = nil) {
        _store = StateObject(wrappedValue: MomentsStore(api: api, who: who))
    }

    private var isMine: Bool { store.owner == "user" }

    var body: some View {
        ZStack(alignment: .bottom) {
            MomentsFog().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    cover
                    if !store.activity.isEmpty {
                        Button { showActivity = true } label: { activityBubble }
                            .buttonStyle(.plain)
                            .padding(.top, 52)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(store.moments) { m in
                            post(m)
                            Divider().opacity(0.35).padding(.leading, 70)
                        }
                    }
                    .padding(.top, store.activity.isEmpty ? 64 : 18)
                    if store.moments.isEmpty {
                        Text(store.who == nil ? "还没有人发朋友圈——右上角相机发第一条" : "这里还什么都没有")
                            .font(Typo.sans(13.5)).foregroundStyle(theme.inkDim).padding(.top, 40)
                    }
                    Color.clear.frame(height: replying == nil ? 40 : 90)
                }
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { g in g.contentOffset.y + g.contentInsets.top } action: { _, y in
                pull = max(0, -y)
            }
            .onScrollPhaseChange { old, new in
                if old == .interacting, new != .interacting, pull > 70, !refreshing {
                    refreshing = true
                    Task {
                        await store.load()
                        try? await Task.sleep(for: .milliseconds(500))
                        refreshing = false
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded {
                if let open = menuFor { justClosed = (open, Date()) }
                menuFor = nil
                if replying != nil && draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    inputFocused = false
                    replying = nil
                }
            })

            topBar
            pullSpinner
            if replying != nil { commentBar }
        }
        .environment(\.colorScheme, .light)
        .task { await store.load() }
        .confirmationDialog("删除这条评论？", isPresented: Binding(get: { deletingComment != nil },
                                                             set: { if !$0 { deletingComment = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let c = deletingComment { Task { await store.deleteComment(c) } }
                deletingComment = nil
            }
        }
        .alert("签名", isPresented: $editingSig) {
            TextField("一句话", text: $sigDraft)
            Button("好") { Task { await store.setSignature(sigDraft.trimmingCharacters(in: .whitespaces)) } }
            Button("取消", role: .cancel) {}
        } message: { Text("在你的头像下面，大家都看得到") }
        .overlay(alignment: .top) {
            if let e = store.error {
                Text(e).font(Typo.sans(13, .medium)).foregroundStyle(theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foodGlass(in: Capsule())
                    .padding(.top, 60)
                    .onTapGesture { store.error = nil }
                    .task { try? await Task.sleep(for: .seconds(4)); store.error = nil }
            }
        }
        .sheet(isPresented: $composing) {
            MomentComposer(store: store).environmentObject(theme)
        }
        .sheet(isPresented: $showActivity, onDismiss: { store.markSeen() }) {
            MomentActivityList(items: store.activity).environmentObject(model).environmentObject(theme)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $viewing) { v in PhotoPager(urls: v.urls, index: v.index) }
        .fullScreenCover(item: Binding(get: { visiting.map { Visit(who: $0) } }, set: { visiting = $0?.who })) { v in
            MomentsView(api: store.api, who: v.who).environmentObject(model).environmentObject(theme)
        }
        .confirmationDialog("换封面？", isPresented: $askCover, titleVisibility: .visible) {
            Button("从相册选一张") { pickingCover = true }
        }
        .photosPicker(isPresented: $pickingCover, selection: $coverPick, matching: .images)
        .onChange(of: coverPick) { _, item in
            guard let item else { return }
            Task {
                if let raw = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: raw),
                   let d = img.jpegData(compressionQuality: 0.85) {
                    await store.setCover(d)
                }
                coverPick = nil
            }
        }
        .onDisappear { if store.who == nil && store.activity.isEmpty { store.markSeen() } }
    }

    private struct Visit: Identifiable { let who: String; var id: String { who } }

    // ── 顶上：返回 / 相机
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.inkDim).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foodGlass(interactive: true, in: Circle())
            Spacer()
            if store.who == nil {
                Button { composing = true } label: {
                    Image(systemName: "camera").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.inkDim).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foodGlass(interactive: true, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .contentShape(Rectangle())
        .onTapGesture {}
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // ── 封面：点一下换；右下角头像和名字压在封面边上，签名在头像下面
    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.frame(height: Self.coverHeight).frame(maxWidth: .infinity)
                .background(alignment: .bottom) { coverArt }
                .overlay(alignment: .bottom) {
                    Color.clear.frame(height: Self.coverHeight - 120)
                        .contentShape(Rectangle())
                        .onTapGesture { askCover = true }
                }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(alignment: .bottom, spacing: 14) {
                    Text(store.profile?.name ?? "").font(Typo.accent(20, .semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 4)
                        .padding(.bottom, 44)
                    MomentAvatar(who: store.owner, size: 72)
                }
                signature
            }
            .padding(.trailing, 18)
            .offset(y: 30 + (signatureText.isEmpty && !isMine ? 0 : 20))
        }
    }

    private var signatureText: String { store.profile?.signature ?? "" }

    private var signature: some View {
        Text(signatureText.isEmpty ? (isMine ? String(localized: "点这里写签名") : "") : signatureText)
            .font(Typo.sans(13))
            .foregroundStyle(signatureText.isEmpty ? theme.inkDim.opacity(0.6) : theme.inkDim)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 260, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isMine else { return }
                sigDraft = signatureText
                editingSig = true
            }
    }

    private var coverArt: some View {
        Group {
            if store.profile?.hasCover == true {
                AuthImageView(urlPath: store.coverPath)
            } else {
                LinearGradient(colors: [theme.accentSoft, theme.accent.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .center) {
                        Label("点一下换封面", systemImage: "photo")
                            .font(Typo.sans(13)).foregroundStyle(.white.opacity(0.85))
                    }
            }
        }
        .frame(height: Self.coverHeight + pull)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// 左上角的彩色光圈（微信朋友圈那只）：拉的时候跟着转，刷新时一直转
    private var pullSpinner: some View {
        let show = pull > 8 || refreshing
        return TimelineView(.animation(paused: !refreshing)) { t in
            let spin = refreshing ? t.date.timeIntervalSinceReferenceDate * 360 : Double(pull) * 3
            Image(systemName: "camera.aperture")
                .font(.system(size: 22))
                .foregroundStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red],
                                                 center: .center))
                .rotationEffect(.degrees(spin))
                .padding(1)
                .background(Circle().fill(.white))
        }
        .opacity(show ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: show)
        .padding(.leading, 22)
        .padding(.top, 70 + min(pull, 60) * 0.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var activityBubble: some View {
        HStack(spacing: 8) {
            if let first = store.activity.first { MomentAvatar(who: first.who, size: 26) }
            Text("\(store.activity.count) 条新互动").font(Typo.sans(14, .medium)).foregroundStyle(theme.ink)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(theme.inkDim)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foodGlass(interactive: true, in: Capsule())
    }

    // ── 一条动态
    private func post(_ m: MomentDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MomentAvatar(who: m.author, size: 44)
                .onTapGesture { if m.author != store.who { visiting = m.author } }
            VStack(alignment: .leading, spacing: 8) {
                Text(m.name).font(Typo.sans(15.5, .semibold)).foregroundStyle(theme.accentDeep)
                    .onTapGesture { if m.author != store.who { visiting = m.author } }
                if !m.content.isEmpty {
                    Text(m.content).font(Typo.sans(15.5)).foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if m.images > 0 { photoGrid(m.imagePaths) }
                HStack(spacing: 12) {
                    Text(MomentsTime.when(m.createdAt)).font(Typo.sans(12.5)).foregroundStyle(theme.inkDim)
                    if m.author == "user" {
                        Button("删除") { Task { await store.delete(m) } }
                            .font(Typo.sans(12.5)).foregroundStyle(theme.accentDeep.opacity(0.8))
                    }
                    Spacer()
                    if menuFor == m.id { actionMenu(m) }
                    Button {
                        let wasJustClosed = justClosed.map { $0.id == m.id && Date().timeIntervalSince($0.at) < 0.4 } ?? false
                        justClosed = nil
                        withAnimation(.easeOut(duration: 0.18)) {
                            menuFor = (menuFor == m.id || wasJustClosed) ? nil : m.id
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.accentDeep)
                            .frame(width: 34, height: 22)
                            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                if !m.likes.isEmpty || !m.comments.isEmpty { interactions(m) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func actionMenu(_ m: MomentDTO) -> some View {
        let liked = m.likes.contains { $0.who == "user" }
        return HStack(spacing: 0) {
            Button {
                menuFor = nil
                Task { await store.toggleLike(m) }
            } label: {
                Label(liked ? "取消" : "赞", systemImage: liked ? "heart.slash" : "heart").frame(width: 78, height: 34)
            }
            Divider().frame(height: 18).overlay(.white.opacity(0.4))
            Button {
                menuFor = nil
                replying = (m, nil)
                inputFocused = true
            } label: {
                Label("评论", systemImage: "text.bubble").frame(width: 78, height: 34)
            }
        }
        .font(Typo.sans(13.5, .medium))
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
    }

    private func photoGrid(_ urls: [String]) -> some View {
        let cols = urls.count == 1 ? 1 : (urls.count == 2 || urls.count == 4 ? 2 : 3)
        let side: CGFloat = urls.count == 1 ? 190 : 84
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 5), count: cols),
                         alignment: .leading, spacing: 5) {
            ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                AuthImageView(urlPath: u)
                    .frame(width: side, height: side)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { viewing = ViewedPhoto(urls: urls, index: i) }
            }
        }
    }

    private func interactions(_ m: MomentDTO) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !m.likes.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart").font(.system(size: 12, weight: .semibold))
                    Text(m.likes.map(\.name).joined(separator: "，")).font(Typo.sans(14, .medium))
                }
                .foregroundStyle(theme.accentDeep)
            }
            if !m.likes.isEmpty && !m.comments.isEmpty { Divider().opacity(0.4) }
            ForEach(m.comments) { c in
                commentLine(c)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if c.author == "user" { deletingComment = c; return }   // 点自己的 = 问删不删；点别人的 = 回复
                        replying = (m, c)
                        inputFocused = true
                    }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 6))
    }

    private func commentLine(_ c: MomentCommentDTO) -> some View {
        var t = Text(c.name).foregroundColor(theme.accentDeep).fontWeight(.medium)
        if let to = c.replyToName {
            t = t + Text(" 回复 ").foregroundColor(theme.ink) + Text(to).foregroundColor(theme.accentDeep).fontWeight(.medium)
        }
        return (t + Text("：").foregroundColor(theme.ink) + Text(c.content).foregroundColor(theme.ink))
            .font(Typo.sans(14))
            .fixedSize(horizontal: false, vertical: true)
    }

    // ── 底下评论输入条
    private var commentBar: some View {
        HStack(spacing: 10) {
            TextField(replying?.to.map { String(localized: "回复 \($0.name)") } ?? String(localized: "评论"), text: $draft)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { sendComment() }
                .font(Typo.sans(15))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
            Button { sendComment() } label: {
                Text("发送").font(Typo.sans(15, .semibold))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? theme.inkDim : theme.accentDeep)
                    .frame(minWidth: 52, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foodGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func sendComment() {
        guard let r = replying else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        replying = nil
        inputFocused = false
        Task { await store.comment(r.moment, text, replyTo: r.to?.id) }
    }
}

/// 背景（10-01 Tilia）：主页同一张壁纸，四边往中间漫的发亮白雾——边上几乎全白，中心隐约透出壁纸
struct MomentsFog: View {
    var body: some View {
        ZStack {
            AppBackground().blur(radius: 6)
            EllipticalGradient(colors: [.white.opacity(0.28), .white.opacity(0.62), .white.opacity(0.9), .white.opacity(0.97)],
                               center: .center, startRadiusFraction: 0.0, endRadiusFraction: 0.72)
            // 四条边再各压一道，让白雾是「从边上往里漫」的
            VStack(spacing: 0) {
                LinearGradient(colors: [.white.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                Spacer()
                LinearGradient(colors: [.clear, .white.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 160)
            }
            HStack(spacing: 0) {
                LinearGradient(colors: [.white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 70)
                Spacer()
                LinearGradient(colors: [.clear, .white.opacity(0.7)], startPoint: .leading, endPoint: .trailing).frame(width: 70)
            }
        }
    }
}

/// 头像：你用名字首字，联系人用它的头像（圆角方，微信朋友圈那样）
struct MomentAvatar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    let who: String
    var size: CGFloat = 44

    var body: some View {
        let comp = model.companions.first { $0.id.uuidString.lowercased() == who }
        Group {
            if let c = comp, let img = model.avatarImages[c.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [theme.accentSoft, theme.accent.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String((comp?.name ?? model.profile?.name ?? "我").prefix(1)))
                        .font(Typo.accent(size * 0.45)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

/// 发一条：文字 + 最多 9 张图
struct MomentComposer: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MomentsStore
    @State private var text = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("这一刻的想法…", text: $text, axis: .vertical)
                        .focused($focused)
                        .lineLimit(4...12)
                        .font(Typo.sans(16))
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { focused = true }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: 3),
                              alignment: .leading, spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 96, height: 96).clipped()
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                                    }
                                    .padding(4)
                                }
                        }
                        if images.count < 9 {
                            PhotosPicker(selection: $picks, maxSelectionCount: 9 - images.count, matching: .images) {
                                Image(systemName: "plus").font(.system(size: 26, weight: .light))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, height: 96)
                                    .background(.background.secondary)
                            }
                        }
                    }
                    Text("不推送，谁路过谁看见。它们过一阵会刷到。")
                        .font(Typo.sans(12)).foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .navigationTitle("发朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "发着…" : "发表") {
                        Task {
                            sending = true
                            let ok = await store.post(text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      images: images.compactMap { $0.jpegData(compressionQuality: 0.85) })
                            sending = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(sending || (text.trimmingCharacters(in: .whitespaces).isEmpty && images.isEmpty))
                }
            }
            .onChange(of: picks) { _, items in
                Task {
                    for item in items {
                        if let raw = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: raw) {
                            images.append(img)
                        }
                    }
                    picks = []
                }
            }
            .onAppear { focused = true }
        }
        .tint(theme.accent)
        .environment(\.colorScheme, .light)
    }
}

/// 「N 条新互动」点进去的列表
struct MomentActivityList: View {
    let items: [MomentActivityDTO]

    var body: some View {
        NavigationStack {
            List(items) { it in
                HStack(alignment: .top, spacing: 12) {
                    MomentAvatar(who: it.who, size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.name).font(Typo.sans(15, .semibold))
                        if it.kind == "like" {
                            Image(systemName: "heart").font(.system(size: 14))
                        } else {
                            Text(it.content ?? "").font(Typo.sans(14.5))
                        }
                        Text(MomentsTime.when(it.at)).font(Typo.sans(12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(it.post ?? "").font(Typo.sans(11.5)).foregroundStyle(.secondary)
                        .lineLimit(3).frame(width: 64, height: 64, alignment: .topLeading)
                        .padding(6).background(.background.secondary)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("新互动")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 点图看大图，左右滑
struct PhotoPager: View {
    @Environment(\.dismiss) private var dismiss
    let urls: [String]
    @State var index: Int

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    AuthImageView(urlPath: u, contentMode: .fit).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
        }
        .onTapGesture { dismiss() }
    }
}
