import SwiftUI

/// 导入酒馆角色卡（10-01，设计 specs/2026-10-01-tavern-card-import-design.md）：
/// 选好文件 → 服务器先读一遍给预览（什么都不建）→ TA 挑开场白、选文风 → 导入，进它的第一个窗口。
/// 样子先能用，统一调 UI 时再说。

struct CardFile: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
}

struct CardPreview: Decodable {
    let name: String
    let creator: String
    let creator_notes: String
    let tags: [String]
    let greetings: [String]
    let lore: Int
    let lore_skipped: Int
    let has_image: Bool
    let system_prompt: String
    let post_history: String
    let persona_chars: Int
    let persona_cost: [Double]?
}

struct CardImportView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let file: CardFile
    let done: () -> Void

    @State private var preview: CardPreview?
    @State private var error: String?
    @State private var greeting = 0
    @State private var style = "chat"
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let p = preview { form(p) }
                else if let error { Text(error).foregroundStyle(.red).padding() }
                else { ProgressView() }
            }
            .navigationTitle(String(localized: "导入角色卡"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func form(_ p: CardPreview) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if p.has_image, let img = UIImage(data: file.data) {
                        Image(uiImage: img.squareCropped(to: 256)).resizable().scaledToFill()
                            .frame(width: 64, height: 64).clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).font(Typo.sans(Typo.Size.headline, .semibold))
                        if !p.creator.isEmpty {
                            Text(String(localized: "作者：\(p.creator)")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                        }
                        if !p.tags.isEmpty {
                            Text(p.tags.joined(separator: " · ")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !p.creator_notes.isEmpty {
                    DisclosureGroup(String(localized: "作者的话")) {
                        Text(p.creator_notes).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.secondary)
                    }
                }
            }
            if !p.greetings.isEmpty {
                Section(String(localized: "它的第一句（挑一句）")) {
                    ForEach(Array(p.greetings.enumerated()), id: \.offset) { i, g in
                        Button { greeting = i } label: {
                            HStack(alignment: .top) {
                                Image(systemName: greeting == i ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(theme.accentDeep)
                                Text(g).font(Typo.sans(Typo.Size.callout)).lineLimit(4).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Picker(String(localized: "文风"), selection: $style) {
                    Text(String(localized: "日常聊天")).tag("chat")
                    Text(String(localized: "角色扮演（长文）")).tag("long")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(style == "long"
                     ? String(localized: "像写小说一样：场景、动作、心理都写出来。之后在 TA 的设定里随时能改。")
                     : String(localized: "像发微信一样：短短几句，一条一条发。之后在 TA 的设定里随时能改。"))
            }
            Section {
                Text(p.lore_skipped > 0 ? String(localized: "世界书：\(p.lore) 条（另有 \(p.lore_skipped) 条读不了，跳过）")
                                        : String(localized: "世界书：\(p.lore) 条"))
                if let cost = p.persona_cost, cost.count == 2 {
                    Text(String(localized: "这份人设大约 \(p.persona_chars) 字，每轮多花约 \(String(format: "$%.5f", cost[0]))（走缓存时）"))
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                }
                if !p.system_prompt.isEmpty {
                    DisclosureGroup(String(localized: "作者写给模型的说明（会放进人设里）")) {
                        Text(p.system_prompt).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                    }
                }
                if !p.post_history.isEmpty {
                    DisclosureGroup(String(localized: "作者的附加指令（不会用）")) {
                        Text(p.post_history).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(String(localized: "导进来以后它会记得你、会主动来找你，跟别的联系人一样；记忆从现在开始记。"))
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                Button { Task { await importNow() } } label: {
                    Text(saving ? "…" : String(localized: "导入，开始聊")).frame(maxWidth: .infinity)
                        .font(Typo.sans(Typo.Size.headline, .semibold))
                }
                .disabled(saving)
            }
        }
    }

    private func load() async {
        do {
            let out = try await model.api.importCard(file.data, fileName: file.name, preview: true)
            preview = try JSONDecoder().decode(CardPreview.self, from: out)
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = String(localized: "读不出这张卡")
        }
    }

    private func importNow() async {
        saving = true
        defer { saving = false }
        do {
            try await model.importCard(file.data, fileName: file.name, greeting: greeting, style: style)
            dismiss()
            done()
        } catch let e as APIError {
            error = e.message
        } catch {
            self.error = String(localized: "没导进去，再试一次")
        }
    }
}
