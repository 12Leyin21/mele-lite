import SwiftUI

// MARK: - 阅读器（10-02，照之前自用的 App BookReaderView）
//
// 一章一屏往下滑；选中一段 →「划线」（安静的，只落在页上）或「划线说两句」（选一个联系人，这句话带着原文发进你们的聊天，
// 它在聊天里回，回话同时抄进页边）。点一道划线 → 开那一句的页边，看两个人在这句底下的往来。
// 翻到哪、这一章第几屏，随时报给服务器：它的〔在读〕就是这么来的；开着每分钟记一次时长。

struct BookReaderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let book: BookDTO

    @AppStorage("readerFontSize") private var fontSize = 17.0
    /// 护眼模式（照之前自用的 App）：glass 玻璃 / paper 纸墨 / night 夜间
    @AppStorage("readerTheme") private var readerTheme = "glass"
    @State private var chapters: [ChapterDTO] = []
    @State private var current = 0
    @State private var text = ""
    @State private var marks: [BookMarkDTO] = []
    @State private var page = 0
    @State private var pageCount = 1
    @State private var composing: Draft?
    @State private var thread: BookMarkDTO?
    @State private var showMarks = false
    @State private var showChapters = false
    @State private var error: String?

    struct Draft: Identifiable { let id = UUID(); let quote: String; let pos: Int }

    private var api: APIClient { session.api }

    /// 正文板的底、整页的底、正文字色、标题色（照之前自用的 App 09-06：夜间整页都暗，不只是书页）
    private var colors: (panel: Color?, page: Color?, text: UIColor, title: Color) {
        switch readerTheme {
        case "paper": return (Color(red: 0.96, green: 0.93, blue: 0.85), Color(red: 0.91, green: 0.87, blue: 0.78),
                              UIColor(red: 0.20, green: 0.17, blue: 0.13, alpha: 1), Color(red: 0.20, green: 0.17, blue: 0.13))
        case "night": return (Color(red: 0.10, green: 0.10, blue: 0.13), Color(red: 0.05, green: 0.05, blue: 0.07),
                              UIColor(white: 0.87, alpha: 1), Color(white: 0.9))
        default: return (nil, nil, UIColor(theme.ink), theme.ink)
        }
    }
    /// 顶栏底栏的字色跟着主题：夜间浅、纸墨深棕、玻璃照旧
    private var chrome: Color { readerTheme == "glass" ? theme.accentDeep : colors.title.opacity(0.75) }
    private var chromeFill: Color { readerTheme == "night" ? Color.white.opacity(0.08) : Color.white.opacity(0.4) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                    SelectableText(text: text, fontSize: fontSize, textColor: colors.text, highlights: highlights,
                                   onHighlight: { quote, pos in Task { await addMark(quote: quote, pos: pos, note: "", to: nil) } },
                                   onAnnotate: { quote, pos in composing = Draft(quote: quote, pos: pos) },
                                   onTapHighlight: { loc in thread = root(at: loc) })
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radii.card, style: .continuous).fill(colors.panel ?? Color.white.opacity(0.55)))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .id(current)
            .onScrollGeometryChange(for: [CGFloat].self) { g in
                [g.contentOffset.y, g.contentSize.height, g.containerSize.height]
            } action: { _, v in
                let h = max(v[2], 1)
                let count = max(1, Int(ceil(v[1] / h)))
                let p = min(count - 1, max(0, Int((v[0] + h * 0.3) / h)))
                if p != page || count != pageCount {
                    page = p
                    pageCount = count
                    Task { await report(seconds: 0) }
                }
            }
            bottomBar
        }
        .background { if let page = colors.page { page.ignoresSafeArea() } else { AppBackground() } }
        .environment(\.colorScheme, readerTheme == "night" ? .dark : .light)
        .task {
            current = book.atChapter
            chapters = (try? await api.call("GET", "books/\(book.id)/chapters")) ?? []
            await open(current)
        }
        .task {                                                // 开着每分钟记一次时长
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await report(seconds: 60)
            }
        }
        .sheet(item: $composing) { d in
            MarkCompose(quote: d.quote) { note, to in
                Task { await addMark(quote: d.quote, pos: d.pos, note: note, to: to) }
            }
            .environmentObject(model).environmentObject(theme)
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $thread) { root in
            MarkThread(book: book, root: root, all: $marks).environmentObject(model).environmentObject(theme)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showMarks) { marksList.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showChapters) { chapterList.presentationDetents([.large]) }
    }

    // MARK: 顶上 / 底下

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(Typo.icon(16, .semibold)).foregroundStyle(colors.title)
                    .frame(width: 34, height: 34).background(Circle().fill(chromeFill))
            }
            VStack(spacing: 1) {
                Text(book.title).font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(colors.title).lineLimit(1)
                Text(chapters.indices.contains(current) ? chapters[current].title : "")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(colors.title.opacity(0.55)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            Menu {
                Section("字号") {
                    Button { fontSize = min(26, fontSize + 1) } label: { Label("调大", systemImage: "plus") }
                    Button { fontSize = max(13, fontSize - 1) } label: { Label("调小", systemImage: "minus") }
                }
                Section("护眼模式") {
                    Button { readerTheme = "glass" } label: { Label("玻璃\(readerTheme == "glass" ? " ✓" : "")", systemImage: "drop") }
                    Button { readerTheme = "paper" } label: { Label("纸墨\(readerTheme == "paper" ? " ✓" : "")", systemImage: "doc.plaintext") }
                    Button { readerTheme = "night" } label: { Label("夜间\(readerTheme == "night" ? " ✓" : "")", systemImage: "moon") }
                }
            } label: {
                Text("Aa").font(Typo.accent(Typo.Size.body)).foregroundStyle(chrome)
                    .frame(width: 34, height: 34).background(Circle().fill(chromeFill))
            }
            Button { showMarks = true } label: {
                Image(systemName: "highlighter").font(Typo.icon(15)).foregroundStyle(chrome)
                    .frame(width: 34, height: 34).background(Circle().fill(chromeFill))
            }
            .accessibilityLabel("页边")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack {
            Button { Task { await open(current - 1) } } label: { Label("上一章", systemImage: "chevron.left") }
                .disabled(current == 0).opacity(current == 0 ? 0.35 : 1)
            Spacer()
            Button { showChapters = true } label: {
                Text("\(current + 1) / \(max(chapters.count, 1))").font(Typo.number(Typo.Size.callout))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(chromeFill))
            }
            Spacer()
            Button { Task { await open(current + 1) } } label: {
                HStack(spacing: 4) { Text("下一章"); Image(systemName: "chevron.right") }
            }
            .disabled(current >= chapters.count - 1).opacity(current >= chapters.count - 1 ? 0.35 : 1)
        }
        .font(Typo.sans(Typo.Size.callout, .semibold))
        .foregroundStyle(chrome)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: 读

    private func open(_ i: Int) async {
        guard i >= 0, chapters.isEmpty || i < chapters.count else { return }
        do {
            let ch: ChapterTextDTO = try await api.call("GET", "books/\(book.id)/chapters/\(i)")
            current = i
            text = ch.text
            page = 0
            marks = (try? await api.call("GET", "books/\(book.id)/marks")) ?? marks
            error = nil
            await report(seconds: 0)
        } catch {
            self.error = "这一章没拉下来：\(error.localizedDescription)"
        }
    }

    private func report(seconds: Int) async {
        _ = try? await api.raw("POST", "books/\(book.id)/reading",
                               json: ["chapter": current, "page": page, "page_count": pageCount, "seconds": seconds])
    }

    // MARK: 页边

    /// 这一章铺出来的划线：TA 的用主题色，联系人的按联系人分颜色
    private var highlights: [TextHighlight] {
        marks.filter { $0.chapter == current && $0.parentID == nil && !$0.quote.isEmpty }.map {
            TextHighlight(text: $0.quote, location: $0.pos >= 0 ? $0.pos : nil, color: color(for: $0.author))
        }
    }

    private func color(for author: String) -> UIColor {
        if author == "user" { return UIColor(theme.accentDeep) }
        let palette: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange, .systemGreen]
        let i = model.companions.firstIndex { $0.id.uuidString.lowercased() == author.lowercased() } ?? 0
        return palette[i % palette.count]
    }

    /// 点到的那道划线（按位置找；位置对不上的老划线按第一处找）
    private func root(at loc: Int) -> BookMarkDTO? {
        let ns = text as NSString
        return marks.first { m in
            guard m.chapter == current, m.parentID == nil, !m.quote.isEmpty else { return false }
            let start = m.pos >= 0 ? m.pos : ns.range(of: m.quote).location
            return start == loc || ns.range(of: m.quote).location == loc
        }
    }

    private func addMark(quote: String, pos: Int, note: String, to companion: UUID?) async {
        var body: [String: Any] = ["chapter": current, "quote": quote, "note": note, "pos": pos]
        if let companion { body["companion_id"] = companion.uuidString.lowercased() }
        guard let made: BookMarkDTO = try? await api.call("POST", "books/\(book.id)/marks", json: body) else {
            error = "没划上，再试一次"
            return
        }
        marks.append(made)
        if let companion { await BookTalk.send(made, quote: quote, note: note, companion: companion, model: model, api: api) }
    }

    private var marksList: some View {
        NavigationStack {
            List {
                let roots = marks.filter { $0.parentID == nil }
                if roots.isEmpty {
                    Text("这本书还没有划线。选中一段字就能划。").foregroundStyle(theme.inkDim)
                }
                ForEach(roots) { m in
                    Button {
                        showMarks = false
                        Task {
                            if m.chapter != current { await open(m.chapter) }
                            try? await Task.sleep(for: .milliseconds(350))
                            thread = m
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("「\(m.quote)」").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink).lineLimit(3)
                            if !m.note.isEmpty {
                                Text(m.note).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).lineLimit(2)
                            }
                            Text("\(who(m.author)) · \(chapters.indices.contains(m.chapter) ? chapters[m.chapter].title : "")"
                                 + (replies(m) > 0 ? " · \(replies(m)) 条往来" : ""))
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                    }
                }
            }
            .navigationTitle("页边").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func replies(_ m: BookMarkDTO) -> Int { marks.filter { $0.parentID == m.id }.count }

    private func who(_ author: String) -> String {
        author == "user" ? String(localized: "我") : (model.companions.first { $0.id.uuidString.lowercased() == author.lowercased() }?.name ?? "Ta")
    }

    private var chapterList: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters) { c in
                    Button {
                        showChapters = false
                        Task { await open(c.index) }
                    } label: {
                        HStack {
                            Text(c.title).foregroundStyle(c.index == current ? theme.accentDeep : theme.ink)
                            Spacer()
                            if c.index == current { Image(systemName: "bookmark.fill").foregroundStyle(theme.accentDeep) }
                        }
                    }
                    .id(c.index)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 「划线说两句」发进聊天：那个联系人最近的窗口，原文当引用，带着 book_mark_id（服务器把它接下来的回话抄进页边）
enum BookTalk {
    @MainActor
    static func send(_ mark: BookMarkDTO, quote: String, note: String, companion: UUID, model: AppModel, api: APIClient) async {
        guard let conv = model.latestConversation(companion) else { return }
        let short = quote.count > 40 ? String(quote.prefix(40)) + "…" : quote
        let body = note.isEmpty ? "「回复：\(short)」\n（划了这一句）" : "「回复：\(short)」\n\(note)"
        _ = try? await api.raw("POST", "conversations/\(conv.id.uuidString.lowercased())/messages",
                               json: ["text": body, "book_mark_id": mark.parentID ?? mark.id,
                                      "client_id": UUID().uuidString.lowercased()])
    }
}

/// 划线说两句：写一句，选说给谁（默认主联系人）
struct MarkCompose: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let quote: String
    var onSend: (String, UUID?) -> Void
    @State private var note = ""
    @State private var to: UUID?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("「\(quote)」").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim).lineLimit(6)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(Color.white.opacity(0.45)))
                TextField("想说什么…", text: $note, axis: .vertical)
                    .lineLimit(3...8).font(Typo.sans(Typo.Size.body))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(Color.white.opacity(0.7)))
                if model.companions.count > 1 {
                    Picker("说给谁", selection: Binding(get: { to ?? model.companions.first?.id }, set: { to = $0 })) {
                        ForEach(model.companions) { c in Text(c.name).tag(Optional(c.id)) }
                    }
                    .pickerStyle(.menu)
                }
                Text("这句话会带着原文发进你们的聊天，它的回话也会留在这一句的页边。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                Spacer()
            }
            .padding(18)
            .background(AppBackground())
            .navigationTitle("划线说两句").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发") {
                        onSend(note.trimmingCharacters(in: .whitespacesAndNewlines), to ?? model.companions.first?.id)
                        dismiss()
                    }
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}

/// 一句的页边：线头 + 两个人的往来；能接着回（回的话也发进聊天，它会接着答）
struct MarkThread: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    let book: BookDTO
    let root: BookMarkDTO
    @Binding var all: [BookMarkDTO]
    @State private var draft = ""

    private var items: [BookMarkDTO] { [root] + all.filter { $0.parentID == root.id }.sorted { $0.id < $1.id } }
    private var partner: UUID? { root.companionID ?? model.companions.first?.id }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("「\(root.quote)」").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(Color.white.opacity(0.45)))
                        ForEach(items.filter { !$0.note.isEmpty }) { m in
                            HStack(alignment: .top, spacing: 8) {
                                avatar(m)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name(m)).font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.inkFaint)
                                    Text(m.note).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        if items.count == 1 && root.note.isEmpty {
                            Text("只划了线，还没说话。").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkFaint)
                        }
                    }
                    .padding(18)
                }
                HStack(spacing: 8) {
                    TextField("在这句底下说…", text: $draft, axis: .vertical).lineLimit(1...4)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.7)))
                    Button { Task { await reply() } } label: {
                        Image(systemName: "arrow.up").font(Typo.icon(15, .bold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Circle().fill(theme.accentDeep))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
            }
            .background(AppBackground())
            .navigationTitle("页边").navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.colorScheme, .light)
        .task {                         // 它的回话是聊天那一轮回完才抄进来的：开着就隔几秒拉一次
            while !Task.isCancelled {
                if let got: [BookMarkDTO] = try? await session.api.call("GET", "books/\(book.id)/marks") { all = got }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func reply() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        var body: [String: Any] = ["parent_id": root.id, "note": text]
        if let partner { body["companion_id"] = partner.uuidString.lowercased() }
        guard let made: BookMarkDTO = try? await session.api.call("POST", "books/\(book.id)/marks", json: body) else { return }
        all.append(made)
        if let partner { await BookTalk.send(made, quote: root.quote, note: text, companion: partner, model: model, api: session.api) }
    }

    private func name(_ m: BookMarkDTO) -> String {
        m.mine ? String(localized: "我") : (model.companion(m.authorID)?.name ?? "Ta")
    }

    @ViewBuilder
    private func avatar(_ m: BookMarkDTO) -> some View {
        if !m.mine, let c = model.companion(m.authorID) {
            CompanionAvatar(companion: c, size: 26)
        } else {
            Circle().fill(theme.accentSoft).frame(width: 26, height: 26)
                .overlay(Text("我").font(Typo.icon(11, .semibold)).foregroundStyle(theme.accentDeep))
        }
    }
}
