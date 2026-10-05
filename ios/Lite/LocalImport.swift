#if LITE
import Foundation
import MeleLiteCore

/// 搬家：导入 ChatGPT / Claude / DeepSeek / Gemini 的官方聊天记录（10-05，设计 docs/superpowers/specs/2026-10-05-chat-import-design.md）。
/// 1. POST import/preview（multipart files）：认包、列对话、估价；解析结果先存在 import-draft.json，免得再传一遍
/// 2. POST companions/{cid}/import {ids, memories}：选中的合成一个新窗口；模型只看最后 40 条，更早的不进上下文也不让回声卷
/// 3. 后台挑记忆：接了记忆库 → 一条条 remember；没接 → 压成一段搬家笔记（companion.import_notes，LocalBrain 放 system 里）
///    GET companions/{cid}/import 看进度；挑到一半关了 App，再看进度时接着挑
/// 连着 Host 时：包照样在这里 read() 认，认好的 draft 发给 Host 的 companions/{cid}/import（server/brain/chat_import.py）
enum LocalImport {
    static let keepLive = 40
    static let draftFile = "import-draft.json"
    nonisolated(unsafe) private static var running: Set<String> = []
    private static let lock = NSLock()

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        switch (r.method, p.count) {
        case ("POST", 2) where p == ["import", "preview"]: return preview(host, r)
        case ("POST", 3) where p[0] == "companions" && p[2] == "import": return start(host, companion: p[1], r.json)
        case ("GET", 3) where p[0] == "companions" && p[2] == "import":
            resumeIfNeeded(host, companion: p[1])
            return .json(status(host.store, p[1]))
        default: return nil
        }
    }

    // MARK: 1. 预览

    static func preview(_ host: LocalHost, _ r: LocalRequest) -> LocalResponse {
        let got: Read
        switch read((r.form.files["files"] ?? []).map(\.data)) {
        case .failure(let e): return .error(400, e.message)
        case .success(let g): got = g
        }
        host.store.write(draftFile, got.draft)
        let cost = r.form.fields["companion_id"].flatMap { host.store.companion($0) }.flatMap { estimate(host, companion: $0, chars: got.chars) }
        var out = got.preview
        out["cost"] = cost ?? NSNull()
        return .json(out)
    }

    struct Failure: Error { let message: String }
    struct Read { let draft: [String: Any]; let preview: [String: Any]; let chars: Int }

    /// 认包（本机搬和连着 Host 搬都在手机上认，10-05）：draft 是认好的整份（Host 收的就是这个形状），preview 给列表页
    static func read(_ files: [Data]) -> Result<Read, Failure> {
        guard !files.isEmpty else { return .failure(Failure(message: String(localized: "选一下导出的文件"))) }
        var chats: [Data] = [], extra: [String] = []
        for f in files {
            let mem = (try? ClaudeMemories.parse(f)) ?? []
            if !mem.isEmpty { extra += mem } else { chats.append(f) }
        }
        let got: (source: ChatSource, conversations: [ImportedConversation])
        do { got = try ChatImport.parse(chats) } catch ChatImportError.mixed {
            return .failure(Failure(message: String(localized: "一次只能搬一家：不同 App 的包分开搬")))
        } catch ChatImportError.needsJSON {
            return .failure(Failure(message: String(localized: "这是 HTML 格式的 Takeout：回 Google Takeout 重新导一次，「我的活动」那一项把格式改成 JSON")))
        } catch {
            return .failure(Failure(message: String(localized: "认不出这个文件：要官方「导出数据」给的压缩包，或者里面的 conversations.json")))
        }
        guard !got.conversations.isEmpty else { return .failure(Failure(message: String(localized: "包里没有聊过天的对话"))) }
        let draft: [String: Any] = [
            "source": got.source.rawValue, "extra": extra,
            "conversations": got.conversations.map { c in
                ["id": c.id, "title": c.title, "created_at": LocalStore.iso(c.createdAt),
                 "messages": c.messages.map { ["role": $0.role.rawValue, "text": $0.text, "at": LocalStore.iso($0.at)] }]
            },
        ]
        let chars = got.conversations.reduce(0) { $0 + $1.chars }
        let preview: [String: Any] = [
            "source": got.source.rawValue, "memory_notes": extra.count, "chars": chars, "cost": NSNull(),
            "conversations": got.conversations.map { c in
                ["id": c.id, "title": c.title.isEmpty ? String(localized: "（没有标题）") : c.title,
                 "first": LocalStore.iso(c.messages.first?.at ?? c.createdAt), "last": LocalStore.iso(c.messages.last?.at ?? c.createdAt),
                 "count": c.messages.count, "chars": c.chars] as [String: Any]
            },
        ]
        return .success(Read(draft: draft, preview: preview, chars: chars))
    }

    /// 挑记忆大约多少钱：输入 ≈ 字数，每块回 300；价目表里没有这个模型就不估
    static func estimate(_ host: LocalHost, companion: [String: Any], chars: Int) -> Double? {
        guard let (p, _) = LocalEcho.models(host, companion).first else { return nil }
        let chunks = max(1, chars / ImportMemory.chunkSize + 1)
        return LocalUsage.cost(["model": p.model, "input": chars + chunks * 600, "output": chunks * 300 + 1500])
    }

    // MARK: 2. 搬

    static func start(_ host: LocalHost, companion cid: String, _ b: [String: Any]) -> LocalResponse {
        let s = host.store
        guard s.companion(cid) != nil else { return .error(404, String(localized: "没有这个联系人")) }
        guard let draft = s.read(draftFile) as? [String: Any], let src = ChatSource(rawValue: draft["source"] as? String ?? "") else {
            return .error(400, String(localized: "先选文件"))
        }
        let want = Set(b["ids"] as? [String] ?? [])
        let convs = (draft["conversations"] as? [[String: Any]] ?? []).compactMap(conversation).filter { want.isEmpty || want.contains($0.id) }
        guard !convs.isEmpty else { return .error(400, String(localized: "至少选一段")) }
        let app = src.appName

        // 一个新窗口，按原时间一次写进去（逐条 addMessage 会把整份文件读写上千遍）
        var c = host.newConversation(cid, incognito: false)
        let conv = c["id"] as? String ?? ""
        var list: [[String: Any]] = [], divider: String?
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        for item in ChatImport.timeline(convs, source: src) {
            switch item {
            case let .divider(title, at):                   // 每段开头那行灰字，挂在这段第一条上
                divider = src == .gemini ? "\(app) · \(day.string(from: at))"          // Gemini 一天一段，标题就是日期
                    : "\(app) ·《\(title.isEmpty ? String(localized: "没有标题") : title)》· \(day.string(from: at))"
            case let .message(m):
                var row: [String: Any] = ["id": s.nextID("message"), "role": m.role.rawValue, "text": m.text, "thinking": "",
                                          "at": LocalStore.iso(m.at), "cards": [[String: Any]](), "attachments": [String](), "imported": src.rawValue]
                if let d = divider { row["divider"] = d; divider = nil }
                list.append(row)
            }
        }
        s.saveMessages(conv, list)
        c["title"] = String(localized: "从 \(app) 搬来的")
        c["last_at"] = list.last?["at"] ?? c["last_at"]
        // 模型只看最后 40 条；更早的不进上下文，也不让回声去卷（回声只留两周，卷了也会掉）
        if list.count > keepLive, let upto = list[list.count - keepLive - 1]["id"] { c["rolled_upto"] = upto }
        c["imported"] = src.rawValue
        s.saveConversation(c)

        let wantsMemory = b["memories"] as? Bool ?? true
        if wantsMemory {
            let chunks = convs.flatMap { ImportMemory.chunks($0, userName: host.profile["name"] as? String ?? "") }
            s.write(jobFile(cid), ["state": "picking", "source": src.rawValue, "chunks": chunks, "done": 0,
                                   "picked": [[String: String]](), "extra": draft["extra"] ?? [String](),
                                   "conversation": conv, "started_at": LocalStore.iso(Date())])
            run(host, companion: cid)
        }
        s.write(draftFile, [String: Any]())
        return .json(["conversation_id": conv, "messages": list.count, "picking": wantsMemory], status: 201)
    }

    static func conversation(_ d: [String: Any]) -> ImportedConversation? {
        guard let id = d["id"] as? String else { return nil }
        let msgs = (d["messages"] as? [[String: Any]] ?? []).compactMap { m -> ImportedMessage? in
            guard let role = Role(rawValue: m["role"] as? String ?? ""), let t = m["text"] as? String else { return nil }
            return ImportedMessage(role: role, text: t, at: LocalStore.date(m["at"]))
        }
        return ImportedConversation(id: id, title: d["title"] as? String ?? "", createdAt: LocalStore.date(d["created_at"]), messages: msgs)
    }

    // MARK: 3. 挑记忆

    static func jobFile(_ cid: String) -> String { "import-job-\(cid).json" }

    static func status(_ s: LocalStore, _ cid: String) -> [String: Any] {
        guard let j = s.read(jobFile(cid)) as? [String: Any] else { return ["state": "idle"] }
        return ["state": j["state"] ?? "idle", "done": j["done"] ?? 0, "total": (j["chunks"] as? [Any])?.count ?? 0,
                "picked": (j["picked"] as? [Any])?.count ?? 0, "to": j["to"] ?? "", "error": j["error"] ?? ""]
    }

    static func resumeIfNeeded(_ host: LocalHost, companion cid: String) {
        guard (host.store.read(jobFile(cid)) as? [String: Any])?["state"] as? String == "picking" else { return }
        run(host, companion: cid)
    }

    static func run(_ host: LocalHost, companion cid: String) {
        guard lock.withLock({ running.insert(cid).inserted }) else { return }
        Task.detached {
            defer { _ = lock.withLock { running.remove(cid) } }
            await pick(host, companion: cid)
        }
    }

    static func pick(_ host: LocalHost, companion cid: String) async {
        let s = host.store
        guard var job = s.read(jobFile(cid)) as? [String: Any], let comp = s.companion(cid),
              let src = ChatSource(rawValue: job["source"] as? String ?? "") else { return }
        let settings = comp["settings"] as? [String: Any] ?? [:]
        let zh = (settings["lang"] as? String ?? "zh") == "zh"
        let name = (comp["persona"] as? [String: Any])?["name"] as? String ?? "Lumi"
        let userName = host.profile["name"] as? String ?? ""
        let legs = LocalEcho.models(host, comp)
        func fail(_ why: String) { job["state"] = "failed"; job["error"] = why; s.write(jobFile(cid), job) }
        guard !legs.isEmpty else { return fail(String(localized: "还没给 TA 配 key，或者还没同意把消息发给这家模型")) }
        let chunks = job["chunks"] as? [String] ?? []
        var picked = (job["picked"] as? [[String: String]] ?? [])
        var done = job["done"] as? Int ?? 0
        while done < chunks.count {
            let prompt = ImportMemory.pickPrompt(chunks[done], name: name, userName: userName, zh: zh)
            guard let reply = await ask(legs, prompt) else { return fail(String(localized: "挑到一半模型没回，过一会儿再打开这里接着挑")) }
            for it in ImportMemory.parsePicked(reply) {
                // 回查原文（照回声）：编出来的事不要
                guard LocalEcho.ground(it.text, source: chunks[done] + "\n" + userName) != nil else { continue }
                picked.append(["day": it.day, "text": it.text])
            }
            done += 1
            job["done"] = done; job["picked"] = picked
            s.write(jobFile(cid), job)
        }
        let extra = job["extra"] as? [String] ?? []
        // 记忆库：一条条 remember（重复的它自己会合并）；没接：压成搬家笔记
        if let sv = host.mcp.memoryServer(s, companion: comp), let client = host.mcp.client(sv) {
            for it in picked {
                let content = (it["day"].map { $0.isEmpty ? "" : "（\($0)）" } ?? "") + (it["text"] ?? "")
                let args = (try? JSONSerialization.data(withJSONObject: ["content": content, "importance": 6, "tags": [src.rawValue]]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                _ = try? await client.call("remember", argumentsJSON: args, timeout: 20)
            }
            for note in extra {
                let args = (try? JSONSerialization.data(withJSONObject: ["content": note, "importance": 7, "tags": [src.rawValue]]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                _ = try? await client.call("remember", argumentsJSON: args, timeout: 20)
            }
            job["to"] = "memory"
        } else {
            let items = picked.map { ImportMemory.Picked(day: $0["day"] ?? "", text: $0["text"] ?? "") }
            let prompt = ImportMemory.notesPrompt(items, extra: extra, source: src, name: name, userName: userName, zh: zh)
            guard let notes = await ask(legs, prompt)?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else {
                return fail(String(localized: "记忆挑好了，整理成笔记时模型没回，过一会儿再打开这里"))
            }
            guard var c = s.companion(cid) else { return }
            var all = (c["import_notes"] as? [[String: Any]] ?? []).filter { ($0["source"] as? String) != src.rawValue }
            all.append(["source": src.rawValue, "text": ImportMemory.clipNotes(notes),
                        "at": LocalStore.iso(Date())])
            c["import_notes"] = all
            s.saveCompanion(c)
            job["to"] = "notes"
        }
        job["state"] = "done"
        s.write(jobFile(cid), job)
    }

    static func ask(_ legs: [(ProviderConfig, String)], _ prompt: String) async -> String? {
        for (p, key) in legs {
            let req = ChatRequest(system: "你是一个仔细的整理员。", turns: [ChatTurn(role: .user, text: prompt)], maxTokens: 4000)
            var text = ""
            do { for try await e in makeClient(p, key: key).stream(req) { if case .text(let t) = e { text += t } } } catch { continue }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// LocalBrain 放 system 里的那段（没接记忆库时）
    static func notesBlock(_ comp: [String: Any], zh: Bool) -> String {
        (comp["import_notes"] as? [[String: Any]] ?? []).compactMap { n -> String? in
            guard let t = n["text"] as? String, !t.isEmpty else { return nil }
            let app = ChatSource(rawValue: n["source"] as? String ?? "")?.appName ?? "Claude"
            return (zh ? "〔从 \(app) 带来的〕以前在 \(app) 上聊过的，记得这些：\n" : "〔Brought over from \(app)〕From your old chats on \(app):\n") + t
        }.joined(separator: "\n\n")
    }
}
#endif
