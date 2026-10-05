import SwiftUI

/// 世界书（09-30，设计 specs/2026-09-30-worldbook-design.md）：密语、网络梗、世界观。
/// 按联系人分组 + 一组「所有人都知道」；TA 能改任何一条（包括它记的）。样子先能用，统一调 UI 时Tilia细说。

extension Notification.Name {
    static let lumiOpenLore = Notification.Name("LumiOpenLore")
}

struct LoreEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let companionID: String?
    let name: String
    let keywords: [String]
    let content: String
    let createdBy: String
    let enabled: Bool
    let constant: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, keywords, content, enabled, constant
        case companionID = "companion_id", createdBy = "created_by"
    }
}

@MainActor
final class LoreStore: ObservableObject {
    @Published var entries: [LoreEntry] = []
    @Published var error: String?
    var api: APIClient?

    func load() async {
        entries = (try? await api?.call("GET", "lore", as: [LoreEntry].self)) ?? entries
    }

    /// existing 空 = 加一条。成功返回 true。
    func save(_ existing: LoreEntry?, body: [String: Any]) async -> Bool {
        error = nil
        do {
            if let e = existing {
                let got: LoreEntry = try await api!.call("PATCH", "lore/\(e.id)", json: body)
                entries = entries.map { $0.id == got.id ? got : $0 }
            } else {
                let got: LoreEntry = try await api!.call("POST", "lore", json: body)
                entries.append(got)
            }
            return true
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = String(localized: "没连上服务器，过会儿再试")
        }
        return false
    }

    func delete(_ e: LoreEntry) async {
        try? await api?.send("DELETE", "lore/\(e.id)")
        entries.removeAll { $0.id == e.id }
    }
}

struct LoreRoomView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = LoreStore()
    @State private var editing: LoreEditTarget?

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    Text(String(localized: "还没有词条。你们的密语、刚火的梗、你的世界观都可以写进来——说到关键词的时候，它就会想起来。"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                }
                ForEach(groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.items) { e in
                            Button { editing = LoreEditTarget(entry: e) } label: { row(e) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) { Task { await store.delete(e) } } label: {
                                        Label(String(localized: "删除"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "世界书"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = LoreEditTarget(entry: nil) } label: { Image(systemName: "plus") }
                }
            }
            .task {
                store.api = model.api
                await store.load()
            }
            .sheet(item: $editing) { t in
                LoreEditView(store: store, entry: t.entry).environmentObject(model).environmentObject(theme)
            }
        }
    }

    private struct Group { let title: String; let items: [LoreEntry] }

    /// 每个联系人一组（按联系人顺序），最后「所有人都知道」
    private var groups: [Group] {
        var out: [Group] = model.companions.compactMap { c in
            let items = store.entries.filter { $0.companionID?.lowercased() == c.id.uuidString.lowercased() }
            return items.isEmpty ? nil : Group(title: c.name, items: items)
        }
        let shared = store.entries.filter { $0.companionID == nil }
        if !shared.isEmpty { out.append(Group(title: String(localized: "所有人都知道"), items: shared)) }
        return out
    }

    private func row(_ e: LoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(e.name).font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                if e.createdBy == "ai" {
                    Text(String(localized: "它记的")).font(Typo.sans(11)).foregroundStyle(theme.accentDeep)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accentDeep.opacity(0.12), in: Capsule())
                }
                if e.constant { Image(systemName: "pin.fill").font(Typo.icon(11)).foregroundStyle(theme.inkDim) }
                if !e.enabled { Text(String(localized: "已关")).font(Typo.sans(11)).foregroundStyle(theme.inkDim) }
            }
            Text(e.keywords.joined(separator: " · ")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            Text(e.content).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).lineLimit(2)
        }
        .opacity(e.enabled ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct LoreEditTarget: Identifiable {
    let entry: LoreEntry?
    var id: String { entry.map { "\($0.id)" } ?? "new" }
}

struct LoreEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LoreStore
    let entry: LoreEntry?

    @State private var name = ""
    @State private var keywords = ""
    @State private var content = ""
    @State private var forWho = ""           // 联系人 id；空 = 所有人都知道
    @State private var enabled = true
    @State private var constant = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "名字，比如「日久方长」"), text: $name)
                    TextField(String(localized: "关键词，用逗号隔开（中文一个字也行）"), text: $keywords)
                } footer: {
                    Text(String(localized: "说到这些词的时候，它就会想起这一条。"))
                }
                Section(String(localized: "内容")) {
                    TextEditor(text: $content).frame(minHeight: 140)
                }
                Section {
                    Picker(String(localized: "给谁"), selection: $forWho) {
                        ForEach(model.companions) { c in Text(c.name).tag(c.id.uuidString.lowercased()) }
                        Text(String(localized: "所有人都知道")).tag("")
                    }
                    Toggle(String(localized: "开着"), isOn: $enabled)
                }
                Section {
                    Toggle(String(localized: "常驻"), isOn: $constant)
                } header: {
                    Text(String(localized: "高级"))
                } footer: {
                    Text(String(localized: "常驻的每一轮都在，不用等说到关键词。适合一直要记着的世界观；改一次会让缓存作废一次。"))
                }
                if let e = store.error {
                    Text(e).foregroundStyle(.red)
                }
                if let entry {
                    Section {
                        Button(String(localized: "删除这一条"), role: .destructive) {
                            Task { await store.delete(entry); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(entry == nil ? String(localized: "加一条") : entry!.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "存")) { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        store.error = nil
        if let e = entry {
            name = e.name; keywords = e.keywords.joined(separator: ", "); content = e.content
            forWho = e.companionID?.lowercased() ?? ""; enabled = e.enabled; constant = e.constant
        } else {
            forWho = model.primaryCompanion?.id.uuidString.lowercased() ?? ""
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let kw = keywords.trimmingCharacters(in: .whitespaces).isEmpty ? name : keywords
        let body: [String: Any] = ["name": name, "keywords": kw, "content": content, "enabled": enabled,
                                   "constant": constant, "companion_id": forWho.isEmpty ? NSNull() : forWho]
        if await store.save(entry, body: body) { dismiss() }
    }
}
