import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书架（10-02，照之前自用的 App BookshelfView：一排排架子，书立着，封面是自己挑的图，头顶一根小进度条，最后一格「＋」导入 txt）

struct BookshelfView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = BooksStore()
    @State private var importing = false
    @State private var reading: BookDTO?
    @State private var renaming: BookDTO?
    @State private var renameDraft = ""
    @State private var coverFor: BookDTO?
    @State private var coverItem: PhotosPickerItem?
    @State private var confirmDelete: BookDTO?

    static let perShelf = 3
    static let coverW: CGFloat = 84
    static let coverH: CGFloat = 124

    private var slots: [BookDTO?] { store.books.map { Optional($0) } + [nil] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let error = store.error {
                        Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red).padding(.bottom, 10)
                    }
                    ForEach(Array(stride(from: 0, to: slots.count, by: Self.perShelf)), id: \.self) { start in
                        shelf(Array(slots[start..<min(start + Self.perShelf, slots.count)]))
                    }
                    if store.loaded && store.books.isEmpty {
                        Text("书架还空着。点「＋」导入一本 txt，翻到哪一页 \(mainName) 都知道，读到想说的就在页边划一句。")
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                            .multilineTextAlignment(.center).padding(.top, 24).padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(AppBackground())
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } } }
        }
        .environment(\.colorScheme, .light)
        .task { await store.load(session.api) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { store.error = "这个文件打不开"; return }
            let name = url.lastPathComponent.lowercased().hasSuffix(".txt") ? url.lastPathComponent : url.lastPathComponent + ".txt"
            Task { await store.add(name: name, data: data, api: session.api) }
        }
        .fullScreenCover(item: $reading, onDismiss: { Task { await store.load(session.api) } }) { b in
            BookReaderView(book: b).environmentObject(model).environmentObject(theme)
        }
        .alert("改书名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("书名", text: $renameDraft)
            Button("好") { if let b = renaming { Task { await store.rename(b, to: renameDraft, api: session.api) } } }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: Binding(get: { coverFor != nil }, set: { if !$0 { coverFor = nil } }),
                      selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            guard let item, let b = coverFor else { return }
            Task {
                if let raw = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: raw),
                   let jpg = img.resizedIfNeeded(maxSide: 900).jpegData(compressionQuality: 0.85) {
                    await store.setCover(b, data: jpg, api: session.api)
                }
                coverItem = nil
                coverFor = nil
            }
        }
        .confirmationDialog("把这本书拿下书架？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("拿下来", role: .destructive) { if let b = confirmDelete { Task { await store.delete(b, api: session.api) } } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("书和书里两个人的划线、页边的话都会一起删掉。")
        }
    }

    private var mainName: String { model.companions.first?.name ?? "Ta" }

    /// 一层架子：书立在木板上
    private func shelf(_ row: [BookDTO?]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(Array(row.enumerated()), id: \.offset) { _, b in
                    if let b { bookSpine(b) } else { addSlot }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [theme.accentSoft, theme.accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .frame(height: 10)
                .shadow(color: theme.accentDeep.opacity(0.18), radius: 6, y: 5)
        }
        .padding(.bottom, 30)
    }

    private func bookSpine(_ b: BookDTO) -> some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                Capsule().fill(Color.white.opacity(0.5))
                    .overlay(alignment: .leading) {
                        Capsule().fill(theme.accentDeep).frame(width: max(3, g.size.width * b.progress))
                    }
            }
            .frame(width: Self.coverW - 12, height: 4)
            cover(b)
                .frame(width: Self.coverW, height: Self.coverH)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 5, x: 2, y: 3)
                .overlay(alignment: .bottomTrailing) {
                    if b.todayMinutes > 0 {
                        Text("\(b.todayMinutes)′").font(Typo.number(Typo.Size.caption)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.35))).padding(4)
                    }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { reading = b }
        .contextMenu {
            Button { renameDraft = b.title; renaming = b } label: { Label("改书名", systemImage: "pencil") }
            Button { coverFor = b } label: { Label("换封面", systemImage: "photo") }
            Button(role: .destructive) { confirmDelete = b } label: { Label("拿下书架", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func cover(_ b: BookDTO) -> some View {
        if b.hasCover {
            AuthImageView(urlPath: b.coverPath)
        } else {
            // 没挑封面：书名做一张纯色封面，颜色按书号轮
            let hues: [Double] = [0.95, 0.58, 0.08, 0.38, 0.75]
            Color(hue: hues[b.id % hues.count], saturation: 0.25, brightness: 0.92)
                .overlay {
                    Text(b.title).font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                        .multilineTextAlignment(.center).lineLimit(5).padding(8)
                }
                .overlay(alignment: .leading) { Rectangle().fill(.black.opacity(0.08)).frame(width: 5) }
        }
    }

    private var addSlot: some View {
        Button { importing = true } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(theme.accentDeep.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .frame(width: Self.coverW, height: Self.coverH)
                .overlay(Image(systemName: "plus").font(Typo.icon(24, .light)).foregroundStyle(theme.accentDeep))
                .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("导入一本 txt")
    }
}
