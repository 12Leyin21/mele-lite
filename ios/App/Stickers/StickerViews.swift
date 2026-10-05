import PhotosUI
import SwiftUI

// MARK: - 表情包（10-01 Tilia：一个库所有联系人共用，某几张可以「只给谁」；它按意思找着发；描述能改）
// 朴素版，样子等统一调 UI。

extension Notification.Name {
    static let lumiOpenStickers = Notification.Name("LumiOpenStickers")
}

struct StickerDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let caption: String
    let mime: String
    let onlyFor: [String]
    let useCount: Int
    enum CodingKeys: String, CodingKey {
        case id, name, caption, mime
        case onlyFor = "only_for", useCount = "use_count"
    }
    var path: String { "stickers/\(id)/image" }
}

private struct UploadResult: Decodable {
    struct Skip: Decodable { let name: String; let reason: String }
    let added: [StickerDTO]
    let skipped: [Skip]
}

/// 认图片字节是什么格式（相册给的是原样字节，gif 要保住能动）
private func sniffMime(_ d: Data) -> (String, String) {
    let b = [UInt8](d.prefix(12))
    if b.starts(with: [0x47, 0x49, 0x46]) { return ("image/gif", "gif") }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
    if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return ("image/webp", "webp") }
    return ("image/jpeg", "jpg")
}

/// Library → 表情包：格子、相册多选加、点开改
struct StickerRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var stickers: [StickerDTO] = []
    @State private var loaded = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var picking = false
    @State private var busy = false
    @State private var note: String?
    @State private var editing: StickerDTO?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let note {
                        Text(note).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    }
                    if loaded && stickers.isEmpty {
                        Text("还没有表情包。点右上角从相册加（一次能选好几张），聊天里长按图片也能「加到表情包」。所有联系人都能用，它会挑着发。")
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(stickers) { s in
                            Button { editing = s } label: {
                                AuthImageView(urlPath: s.path, contentMode: .fit)
                                    .frame(height: 78)
                                    .frame(maxWidth: .infinity)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !s.onlyFor.isEmpty {
                                            Image(systemName: "person.fill").font(Typo.icon(10)).foregroundStyle(theme.accentDeep)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !stickers.isEmpty {
                        Text(String(localized: "\(stickers.count) / 300")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle("表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { picking = true } label: { busy ? AnyView(ProgressView()) : AnyView(Image(systemName: "plus")) }
                        .disabled(busy)
                }
            }
            .photosPicker(isPresented: $picking, selection: $picks, maxSelectionCount: 20, matching: .images)
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                Task { await upload(items) }
            }
            .sheet(item: $editing) { s in
                StickerEditor(sticker: s) { await load() }
                    .environmentObject(model).environmentObject(theme)
            }
        }
        .environment(\.colorScheme, .light)
        .task { await load() }
    }

    private func load() async {
        stickers = (try? await model.api.call("GET", "stickers")) ?? stickers
        loaded = true
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        busy = true
        defer { busy = false; picks = [] }
        var files: [(Data, String, String)] = []
        for (i, item) in items.enumerated() {
            guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
            let (mime, ext) = sniffMime(d)
            files.append((d, "sticker-\(i + 1).\(ext)", mime))
        }
        guard !files.isEmpty else { return }
        do {
            let out = try APIClient.decoder.decode(UploadResult.self, from: try await model.api.uploadStickers(files))
            var bits = [String(localized: "加了 \(out.added.count) 张")]
            if !out.skipped.isEmpty {
                bits.append(String(localized: "\(out.skipped.count) 张没加：") + Set(out.skipped.map(\.reason)).joined(separator: "、"))
            }
            if !out.added.isEmpty { bits.append(String(localized: "描述过一会儿写好")) }
            note = bits.joined(separator: " · ")
            await load()
        } catch { note = error.localizedDescription }
    }
}

/// 点开一张：名字、它看到的描述（能改）、只给谁、删
struct StickerEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let sticker: StickerDTO
    let saved: () async -> Void
    @State private var name = ""
    @State private var caption = ""
    @State private var onlyFor: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AuthImageView(urlPath: sticker.path, contentMode: .fit)
                        .frame(height: 140).frame(maxWidth: .infinity)
                }
                Section("名字") { TextField("可以不起", text: $name) }
                Section {
                    TextEditor(text: $caption).frame(minHeight: 90)
                } header: { Text("它看到的样子") } footer: {
                    Text(caption.isEmpty ? "描述还在写。" : "它按这段描述找表情包；写得不对就改成你的意思（比如「阴阳怪气」）。")
                }
                Section {
                    ForEach(model.companions) { c in
                        Toggle(c.name, isOn: Binding(
                            get: { onlyFor.contains(c.id.uuidString.lowercased()) },
                            set: { on in
                                let id = c.id.uuidString.lowercased()
                                if on { onlyFor.insert(id) } else { onlyFor.remove(id) }
                            }))
                    }
                } header: { Text("只给谁") } footer: {
                    Text("都不选 = 所有联系人都能用。")
                }
                Section {
                    Button("删掉这张", role: .destructive) { Task { await delete() } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("存") { Task { await save() } } }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            name = sticker.name; caption = sticker.caption; onlyFor = Set(sticker.onlyFor)
        }
    }

    private func save() async {
        var body: [String: Any] = ["name": name, "only_for": Array(onlyFor)]
        if caption != sticker.caption { body["caption"] = caption }
        do {
            _ = try await model.api.raw("PATCH", "stickers/\(sticker.id)", json: body)
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        do {
            try await model.api.send("DELETE", "stickers/\(sticker.id)")
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// 聊天里的表情包面板：点一张就发
struct StickerPanel: View {
    @EnvironmentObject private var theme: AppTheme
    let api: APIClient
    let send: (Int) -> Void
    @State private var stickers: [StickerDTO] = []
    @State private var loaded = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            if loaded && stickers.isEmpty {
                Text("还没有表情包。在 Library → 表情包 里从相册加，或者长按聊天里的图「加到表情包」。")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).padding(24)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(stickers) { s in
                    Button { send(s.id) } label: {
                        AuthImageView(urlPath: s.path, contentMode: .fit).frame(height: 72).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(AppBackground())
        .task {
            // 常用的在前
            stickers = ((try? await api.call("GET", "stickers")) as [StickerDTO]? ?? []).sorted { $0.useCount > $1.useCount }
            loaded = true
        }
    }
}
