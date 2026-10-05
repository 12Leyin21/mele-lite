import SwiftUI

/// 关于：版本、许可、致谢（10-05：Lite 并进 Mele 本体后这页没跟过来，补回。照 mele-lite 那版）
struct AboutCard: View {
    @EnvironmentObject private var theme: AppTheme
    @State private var showCredits = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关于").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Text("Mele Lite \(version)").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
            Text("源码公开 · 非商用（PolyForm Noncommercial 1.0.0）。")
                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            Button { showCredits = true } label: {
                HStack {
                    Text("致谢").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(Typo.icon(12)).foregroundStyle(theme.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .sheet(isPresented: $showCredits) { CreditsView().environmentObject(theme) }
    }
}

/// 致谢：读打进包里的 CREDITS.md（mele-lite 仓库那一份，唯一正本），中文 / 英文按系统语言挑一半；
/// 末尾附字体许可原文（OFL 要求随 App 带上）
struct CreditsView: View {
    @EnvironmentObject private var theme: AppTheme

    private var lines: [String] {
        guard let url = Bundle.main.url(forResource: "CREDITS", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let halves = raw.components(separatedBy: "\n---\n")
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
        let text = (zh || halves.count < 2) ? halves[0] : halves[1]
        let all = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in all.enumerated() {
            // 表头那一行（下一行是 |---）、分隔行、引用行都不画
            if line.hasPrefix("|---") || line.hasPrefix("> ") { continue }
            if i + 1 < all.count, all[i + 1].hasPrefix("|---") { continue }
            guard line.hasPrefix("|") else { out.append(line); continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            out.append(cells.count == 2 ? "· \(cells[0]) —— \(cells[1])" : line)
        }
        return out
    }

    private var fontLicense: String {
        guard let url = Bundle.main.url(forResource: "OFL-Ballet", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // 原文按 70 个字母硬断行，手机上会折得很碎：段内的换行并成空格，分隔线不要
        return raw.components(separatedBy: "\n\n")
            .map { $0.components(separatedBy: "\n").filter { !$0.hasPrefix("---") }.joined(separator: " ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("# ") {
                        Text(line.dropFirst(2)).font(Typo.accent(Typo.Size.title)).foregroundStyle(theme.ink).padding(.top, 6)
                    } else if line.hasPrefix("## ") {
                        Text(line.dropFirst(3)).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink).padding(.top, 8)
                    } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                            .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !fontLicense.isEmpty {
                    Text("Ballet · SIL Open Font License 1.1").font(Typo.sans(Typo.Size.headline, .semibold))
                        .foregroundStyle(theme.ink).padding(.top, 20)
                    Text(fontLicense).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(AppBackground().ignoresSafeArea())
        .environment(\.colorScheme, .light)
    }
}
