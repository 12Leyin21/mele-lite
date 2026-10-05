import SwiftUI

// 长按浮层用的零件：表情表、「更多表情」面板、菜单卡的一行。从之前自用的 App ChatView.swift 原样搬（2026-09-06 照 Instagram 做的）。

// MARK: - 更多表情（2026-09-06，照 Instagram 的表情面板）
//
// 顶上搜索（用系统自带的表情英文名，不联网）、「你的表情」六个可自定义、「最近用过」、
// 然后按类铺全表，底下一排分类标签点了跳过去。表情表是从 Unicode 区段现场生成的，
// 不用背一张巨表进 App。
enum EmojiCatalog {
    struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let emojis: [String]
    }

    /// 单码位表情：需要 VS16 才能显示成图的（❤ ☀ 这类）补上 FE0F
    private static func scalars(_ ranges: [ClosedRange<UInt32>]) -> [String] {
        var out: [String] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji else { continue }
                if scalar.properties.isEmojiPresentation {
                    out.append(String(scalar))
                } else if scalar.properties.isEmojiModifierBase || value >= 0x2600 {
                    out.append(String(scalar) + "\u{FE0F}")
                }
            }
        }
        return out
    }

    private static func flags(_ codes: [String]) -> [String] {
        codes.map { code in
            String(code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }.map(Character.init))
        }
    }

    static let sections: [Section] = [
        Section(id: "smileys", title: "Smileys & People", symbol: "face.smiling",
                emojis: scalars([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9D2,
                                 0x1F44B...0x1F450, 0x1F64C...0x1F64F, 0x1F90C...0x1F91F, 0x1F932...0x1F933,
                                 0x1F466...0x1F469, 0x1F46B...0x1F46D, 0x1F48B...0x1F48F, 0x1F491...0x1F491])
                        + ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "❣️"]),
        Section(id: "animals", title: "Animals & Nature", symbol: "pawprint",
                emojis: scalars([0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344, 0x1F490...0x1F490,
                                 0x1F30D...0x1F320, 0x2600...0x2604, 0x2744...0x2744, 0x26A1...0x26A1, 0x1F324...0x1F32C, 0x1F308...0x1F308])),
        Section(id: "food", title: "Food & Drink", symbol: "fork.knife",
                emojis: scalars([0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x2615...0x2615, 0x1F32D...0x1F32F])),
        Section(id: "activity", title: "Activities", symbol: "basketball",
                emojis: scalars([0x26BD...0x26BE, 0x1F3C0...0x1F3CF, 0x1F3D0...0x1F3D3, 0x1F3AE...0x1F3B4, 0x1F3BD...0x1F3BF,
                                 0x1F3F8...0x1F3FA, 0x1F945...0x1F94F, 0x1F3A3...0x1F3AD, 0x1F396...0x1F397, 0x1F3C5...0x1F3C6])),
        Section(id: "travel", title: "Travel & Places", symbol: "car",
                emojis: scalars([0x1F680...0x1F6A6, 0x1F6EB...0x1F6EC, 0x1F3D4...0x1F3DF, 0x1F3E0...0x1F3F0, 0x1F5FA...0x1F5FF,
                                 0x26F5...0x26F5, 0x2708...0x2708, 0x1F6F3...0x1F6F9, 0x1F311...0x1F31F])),
        Section(id: "objects", title: "Objects", symbol: "lightbulb",
                emojis: scalars([0x1F4A1...0x1F4A1, 0x1F4BB...0x1F4FF, 0x1F50A...0x1F53D, 0x1F550...0x1F567, 0x1F4E0...0x1F4FF,
                                 0x231A...0x231B, 0x1F9E0...0x1F9FF, 0x1F393...0x1F393, 0x1F45A...0x1F462, 0x1F48E...0x1F48E])),
        Section(id: "symbols", title: "Symbols", symbol: "textformat.abc",
                emojis: ["✅", "❌", "❗️", "❓", "⭐️", "🌟", "✨", "💫", "💯", "🔥", "💢", "💤", "💦", "💨", "🎵", "🎶", "🔔", "🔕",
                         "♾️", "⚠️", "🚫", "♻️", "✔️", "➕", "➖", "➗", "✖️", "🔞", "📵", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️"]),
        Section(id: "flags", title: "Flags", symbol: "flag",
                emojis: flags(["AU", "CN", "JP", "KR", "US", "GB", "FR", "DE", "IT", "ES", "CA", "NZ", "SG", "TW", "HK", "TH", "VN", "MY",
                               "IN", "RU", "BR", "MX", "AR", "NL", "SE", "NO", "DK", "FI", "CH", "AT", "PT", "GR", "TR", "EG", "ZA", "IE"])
                        + ["🏳️‍🌈", "🏁", "🚩", "🎌"]),
    ]

    // 最近用过（最多 30 个）
    static var recent: [String] { UserDefaults.standard.stringArray(forKey: "emojiRecent") ?? [] }
    static func noteRecent(_ emoji: String) {
        var list = recent.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: "emojiRecent")
    }

    /// 搜索：系统表情名（英文）里含这个词，或者就是那个字符
    static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for section in sections {
            for emoji in section.emojis where !seen.contains(emoji) {
                let name = emoji.unicodeScalars.first?.properties.name?.lowercased() ?? ""
                if emoji == q || name.contains(q) {
                    out.append(emoji); seen.insert(emoji)
                }
            }
        }
        return out
    }
}

struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var customising = false
    @State private var editingSlot: Int? = nil
    @State private var choices = ReactionChoices.current
    @State private var recent = EmojiCatalog.recent

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 搜索
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemFill)))
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                        if !query.isEmpty {
                            let hits = EmojiCatalog.search(query)
                            if hits.isEmpty {
                                Text("No results").font(Typo.sans(Typo.Size.body)).foregroundStyle(.secondary).padding(.top, 20)
                                    .frame(maxWidth: .infinity)
                            } else {
                                grid(hits)
                            }
                        } else {
                            // 你的表情
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Your reactions").font(Typo.sans(Typo.Size.title, .bold))
                                    Spacer()
                                    Button(customising ? "Done" : "Customise") {
                                        customising.toggle()
                                        editingSlot = nil
                                        if !customising { UserDefaults.standard.set(choices, forKey: "reactionChoices") }
                                    }
                                    .font(Typo.sans(Typo.Size.body, .medium))
                                }
                                HStack(spacing: 6) {
                                    ForEach(choices.indices, id: \.self) { i in
                                        Button {
                                            if customising { editingSlot = (editingSlot == i) ? nil : i } else { pick(choices[i]) }
                                        } label: {
                                            Text(choices[i]).font(Typo.icon(34))
                                                .frame(maxWidth: .infinity, minHeight: 52)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .fill(editingSlot == i ? Color.accentColor.opacity(0.18) : Color.clear))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .stroke(customising ? Color.accentColor.opacity(editingSlot == i ? 0.9 : 0.35) : .clear,
                                                                style: StrokeStyle(lineWidth: 1.5, dash: editingSlot == i ? [] : [5, 4])))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if customising {
                                    Text(editingSlot == nil ? "点一个格子，再点下面任意表情替换它" : "现在点下面任意表情，放进这个格子")
                                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(.secondary)
                                }
                            }
                            .id("your")
                            if !recent.isEmpty {
                                section("Recent", id: "recent", recent)
                            }
                            ForEach(EmojiCatalog.sections) { sec in
                                section(sec.title, id: sec.id, sec.emojis)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }

                // 分类条
                Divider()
                HStack(spacing: 0) {
                    tab("clock", id: "recent", proxy)
                    ForEach(EmojiCatalog.sections) { sec in tab(sec.symbol, id: sec.id, proxy) }
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
            }
            .background(Color(.systemBackground))
        }
    }

    private func tab(_ symbol: String, id: String, _ proxy: ScrollViewProxy) -> some View {
        Button {
            query = ""
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
        } label: {
            Image(systemName: symbol)
                .font(Typo.icon(17))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String, id: String, _ emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typo.sans(Typo.Size.title, .bold))
            grid(emojis)
        }
        .id(id)
    }

    private func grid(_ emojis: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(emojis, id: \.self) { emoji in
                Button { pick(emoji) } label: {
                    Text(emoji).font(Typo.icon(34)).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pick(_ emoji: String) {
        if customising {
            guard let slot = editingSlot else { return }
            choices[slot] = emoji
            editingSlot = nil
            UserDefaults.standard.set(choices, forKey: "reactionChoices")
            return
        }
        onPick(emoji)
        dismiss()
    }
}

/// 长按浮层菜单卡里的一行：图标 + 文字，按下去变灰一下，destructive 红字。
struct ActionRowStyle: ButtonStyle {
    let ink: Color
    let isDark: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionRowLabelStyle())
            .font(Typo.sans(Typo.Size.headline))
            .foregroundStyle(configuration.role == .destructive ? Color.red : ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 13)
            // 整行都能点：透明背景不接触摸，右半边空白按了没反应（2026-09-07 Tilia圈出来的）
            .contentShape(Rectangle())
            .background(configuration.isPressed ? (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)).frame(height: 0.5)
            }
    }
}

private struct ActionRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon.frame(width: 22)
            configuration.title
        }
    }
}



/// 长按浮层顶上那排表情，可以在「更多表情」里自定义
enum ReactionChoices {
    static let defaults = ["❤️", "🥺", "😂", "😮", "😭", "🔥"]
    static var current: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: "reactionChoices") ?? []
        return saved.count == 6 ? saved : defaults
    }
}
