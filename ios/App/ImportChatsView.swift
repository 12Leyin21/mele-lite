import SwiftUI
import UniformTypeIdentifiers

/// 从别的 AI 搬过来：ChatGPT / Claude / DeepSeek / Gemini（10-05，设计 docs/superpowers/specs/2026-10-05-chat-import-design.md）：
/// 选官方导出的包 → 看列出来的对话、勾 → 搬成一个新窗口；后台挑记忆，这页能看进度。接口在 Lite/LocalImport.swift。
struct ImportChatsView: View {
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var model: AppModel
    let companion: CompanionDTO

    private struct Item: Identifiable {
        let id: String, title: String, first: String, last: String, count: Int
    }
    @State private var picking = false
    @State private var busy = false
    @State private var error: String?
    @State private var source = ""
    @State private var items: [Item] = []
    @State private var chosen: Set<String> = []
    @State private var notes = 0
    @State private var cost: Double?
    @State private var memories = true
    @State private var moved: String?
    @State private var job: [String: Any] = [:]
    @State private var howOpen = false
    /// 连着 Host 时（10-05）：包在手机上认好，选中的整份发给 Host
    @State private var hostDraft: [String: Any]?

    private var cid: String { companion.id.uuidString.lowercased() }
    private var app: String {
        ["chatgpt": "ChatGPT", "claude": "Claude", "deepseek": "DeepSeek", "gemini": "Gemini"][source] ?? "Claude"
    }

    var body: some View {
        TilePage {
            Tile {
                Text("把你在 ChatGPT、Claude、DeepSeek 或 Gemini 里的聊天搬给\(companion.name)：旧聊天放进一个新窗口，能翻能搜；再从里面挑出值得记住的事，让 TA 记得你。")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink)
                ExpandRow(open: $howOpen) {
                    Text("怎么拿到导出包").font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.ink)
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ChatGPT：头像 → 设置 → 数据控制 → 导出数据。邮件里的链接下载一个 .zip（24 小时内有效）。")
                        Text("Claude（网页版）：头像 → Settings → Privacy → Export data。点下载先拿到一个清单（manifest），清单里有几个分开的包，要的是 conversations 开头的那个（聊得多会有好几个）；memories 开头的是 Claude 记的关于你的事，有就一起选。")
                        Text("DeepSeek：头像 → 设置 → 数据管理 → 导出所有历史对话。下载一个 .zip（7 天内有效），直接选它。")
                        Text("Gemini：打开 takeout.google.com → 先「取消全选」→ 只勾「我的活动」→ 点「包括所有活动数据」只留「Gemini Apps」→ 点「多种格式」把「活动记录」改成 JSON（默认是 HTML，选错了这里认不出）。Gemini 只记一问一答，不分对话，搬过来按天排成一段段。")
                        Text("包可以直接选，也可以在「文件」里解压后选里面的 conversations.json。包只在你手机上读，不会上传到我们这里；连着 Mele Host 的话，选中的对话会发到你自己的 Host 上。")
                    }
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
                Button(busy ? String(localized: "读取中…") : String(localized: "选导出的文件")) { picking = true }
                    .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep).disabled(busy)
                if let error { Text(error).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red) }
            }

            if !items.isEmpty && moved == nil { pickList }
            if let moved { progress(moved) }
        }
        .navigationTitle(String(localized: "从别的 AI 搬过来"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task { await preview(urls) }
        }
        .task { await poll() }
    }

    private var pickList: some View {
        Tile {
            HStack {
                Text("\(app) · \(items.count) 段对话").font(Typo.sans(Typo.Size.callout, .semibold)).foregroundStyle(theme.ink)
                Spacer()
                Button(chosen.count == items.count ? String(localized: "全不选") : String(localized: "全选")) {
                    chosen = chosen.count == items.count ? [] : Set(items.map(\.id))
                }
                .font(Typo.sans(Typo.Size.caption, .medium)).foregroundStyle(theme.accentDeep)
            }
            ForEach(items) { it in
                Button {
                    if chosen.contains(it.id) { chosen.remove(it.id) } else { chosen.insert(it.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: chosen.contains(it.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen.contains(it.id) ? theme.accentDeep : theme.inkFaint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.title).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink).lineLimit(1)
                            Text("\(day(it.first)) – \(day(it.last)) · \(it.count) 条").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Toggle(isOn: $memories) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("挑出值得记住的事").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink)
                    Text(costLine).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
            Button(busy ? String(localized: "搬家中…") : String(localized: "搬过来")) { Task { await start() } }
                .font(Typo.sans(Typo.Size.callout, .medium)).foregroundStyle(theme.accentDeep)
                .disabled(busy || chosen.isEmpty)
        }
    }

    private var costLine: String {
        var s = String(localized: "用你自己的 key 过一遍，在后台慢慢挑")
        if let cost { s += String(localized: "，大约 $\(String(format: cost < 0.1 ? "%.3f" : "%.2f", cost))") }
        if notes > 0 { s += String(localized: "；\(app) 自己记的笔记也一起带上") }
        return s
    }

    private func progress(_ moved: String) -> some View {
        Tile {
            Label(moved, systemImage: "checkmark.circle.fill").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink)
            let state = job["state"] as? String ?? "idle"
            let done = job["done"] as? Int ?? 0, total = job["total"] as? Int ?? 0, picked = job["picked"] as? Int ?? 0
            switch state {
            case "picking":
                HStack(spacing: 8) {
                    ProgressView()
                    Text("在挑记忆 \(done)/\(total)… 可以先去聊天，关掉 App 下次进来会接着挑")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
            case "done":
                Text((job["to"] as? String) == "memory"
                     ? String(localized: "挑出了 \(picked) 件事，存进了记忆库")
                     : String(localized: "挑出了 \(picked) 件事，整理成了一段笔记，\(companion.name)每次聊天都看得到"))
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            case "failed":
                Text(job["error"] as? String ?? String(localized: "没挑完")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red)
            default: EmptyView()
            }
        }
    }

    private func day(_ iso: String) -> String { String(iso.prefix(10)) }

    private func preview(_ urls: [URL]) async {
        busy = true; error = nil
        defer { busy = false }
        var files: [(String, String, String, Data)] = []
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: u) else { continue }
            files.append(("files", u.lastPathComponent, u.pathExtension.lowercased() == "json" ? "application/json" : "application/zip", d))
        }
        #if LITE
        if !Lite.local {
            switch LocalImport.read(files.map(\.3)) {
            case .failure(let e): self.error = e.message
            case .success(let got): hostDraft = got.draft; show(got.preview)
            }
            return
        }
        #endif
        do {
            let out = try await model.api.multipartFields("POST", "import/preview", fields: ["companion_id": cid], files: files)
            show((try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func show(_ o: [String: Any]) {
        source = o["source"] as? String ?? ""
        notes = o["memory_notes"] as? Int ?? 0
        cost = o["cost"] as? Double
        items = (o["conversations"] as? [[String: Any]] ?? []).map {
            Item(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", first: $0["first"] as? String ?? "",
                 last: $0["last"] as? String ?? "", count: $0["count"] as? Int ?? 0)
        }
        chosen = Set(items.map(\.id))
        moved = nil
    }

    private func start() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            var body: [String: Any] = ["ids": Array(chosen), "memories": memories]
            if var draft = hostDraft {                 // 连着 Host：选中的那几段整份发过去
                draft["conversations"] = (draft["conversations"] as? [[String: Any]] ?? []).filter { chosen.contains($0["id"] as? String ?? "") }
                draft["memories"] = memories
                body = draft
            }
            let o = try await model.api.raw("POST", "companions/\(cid)/import", json: body) as? [String: Any] ?? [:]
            hostDraft = nil
            moved = String(localized: "搬了 \(o["messages"] as? Int ?? 0) 条，在「从 \(app) 搬来的」窗口里")
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        job = (try? await model.api.raw("GET", "companions/\(cid)/import") as? [String: Any]) ?? [:]
    }

    /// 在挑的时候每 3 秒看一眼（进来时上次没挑完的也会接着挑）
    private func poll() async {
        await refresh()
        if moved == nil, (job["state"] as? String) == "picking" { moved = String(localized: "旧聊天已经搬好了") }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard (job["state"] as? String) == "picking" else { continue }
            await refresh()
        }
    }
}
