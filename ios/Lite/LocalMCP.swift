#if LITE
import Foundation
import MeleLiteCore

/// 用户自己的 MCP 服务（10-04 Tilia）：Me 里填地址和钥匙，TA 设定里勾能用哪几个。
/// 钥匙在钥匙串（service app.melelite.mcp，账号 = 服务 id），这里只存名字、地址、slug。
/// 对面是记忆库（有 wake / recall / person_upsert）时，TA 会自己想起事，人物卡 / 远事可以交给它管。
final class LocalMCP: @unchecked Sendable {
    struct Server { var id: String; var name: String; var url: String; var slug: String }
    struct Toolbox { var specs: [ToolSpec] = []; var route: [String: (Server, String)] = [:]; var memory: Server? }

    let vault = KeychainVault(service: "app.melelite.mcp")
    private let lock = NSLock()
    private var clients: [String: MCPClient] = [:]
    private var cache: [String: (at: Date, tools: [MCPTool])] = [:]
    private var health: [String: String] = [:]
    private var lastWake: [String: Date] = [:]   // 按对话记

    func servers(_ s: LocalStore) -> [Server] {
        s.collection("mcp_servers").compactMap { d in
            guard let id = d["id"] as? String, let url = d["url"] as? String else { return nil }
            return Server(id: id, name: d["name"] as? String ?? "", url: url, slug: d["slug"] as? String ?? "mcp")
        }
    }

    func client(_ sv: Server) -> MCPClient? {
        guard let url = URL(string: sv.url) else { return nil }
        return lock.withLock {
            if let c = clients[sv.id] { return c }
            let c = MCPClient(url: url, token: vault.get(sv.id))
            clients[sv.id] = c
            return c
        }
    }

    func forget(_ id: String) { lock.withLock { clients[id] = nil; cache[id] = nil; health[id] = nil } }
    func status(_ id: String) -> String? { lock.withLock { health[id] } }

    func tools(_ sv: Server, fresh: Bool = false) async throws -> [MCPTool] {
        if !fresh, let hit = lock.withLock({ cache[sv.id] }), Date().timeIntervalSince(hit.at) < 600 { return hit.tools }
        guard let c = client(sv) else { throw MCPError.badReply }
        do {
            let t = try await c.listTools()
            lock.withLock { cache[sv.id] = (Date(), t); health[sv.id] = nil }
            return t
        } catch {
            mark(sv.id, error)
            throw error
        }
    }

    func mark(_ id: String, _ error: Error) {
        lock.withLock { health[id] = (error as? MCPError) == .unauthorized ? "unauthorized" : "offline" }
    }

    func isMemory(_ tools: [MCPTool]) -> Bool {
        Set(tools.map(\.name)).isSuperset(of: ["wake", "recall", "person_upsert"])
    }

    func isMemoryServer(_ sv: Server) -> Bool {
        lock.withLock { cache[sv.id].map { isMemory($0.tools) } } ?? false
    }

    /// 这个 TA 绑的记忆库（设定里的 memory_server）
    func memoryServer(_ s: LocalStore, companion: [String: Any]) -> Server? {
        let st = companion["settings"] as? [String: Any] ?? [:]
        guard let mid = st["memory_server"] as? String else { return nil }
        return servers(s).first { $0.id == mid }
    }

    /// 这一轮 TA 能用的外面工具。人物卡 / 远事归手机时，记忆库那几样收起来（手机那几样由 LocalTools.specs(hiding:) 收）。
    func toolbox(_ host: LocalHost, companion: [String: Any], incognito: Bool) async -> Toolbox {
        let st = companion["settings"] as? [String: Any] ?? [:]
        let on = Set(st["mcp_servers"] as? [String] ?? [])
        let memoryID = st["memory_server"] as? String
        var box = Toolbox()
        for sv in servers(host.store) where on.contains(sv.id) || sv.id == memoryID {
            guard let tools = try? await tools(sv) else { continue }
            let memory = isMemory(tools)
            if memory && (incognito || sv.id != memoryID) { continue }   // 记忆库只给绑定的那个 TA；无痕不给
            var hide: Set<String> = []
            if memory {
                box.memory = sv
                if (st["memory_people"] as? String ?? "remote") == "local" { hide.formUnion(["person_upsert", "people"]) }
                if (st["memory_dates"] as? String ?? "remote") == "local" { hide.formUnion(["date_add", "dates", "date_resolve", "date_forget"]) }
            }
            for t in tools where !hide.contains(t.name) {
                let name = MCPToolNames.exposed(sv.slug, t.name)
                box.specs.append(ToolSpec(name: name, description: "（来自 \(sv.name)）\(t.description)", parametersJSON: t.inputSchemaJSON))
                box.route[name] = (sv, t.name)
            }
        }
        return box
    }

    /// 跑一次外面的工具，回给模型的话 + 「做了几件事」的卡
    func run(_ call: ToolCall, via: (Server, String), zh: Bool) async -> LocalTools.Outcome {
        let (sv, tool) = via
        guard let c = client(sv) else { return .init(result: "没成：地址不对", card: nil) }
        do {
            let r = try await c.call(tool, argumentsJSON: call.argumentsJSON)
            if r.isError { return .init(result: "没成：\(r.text)", card: nil) }
            let card: [String: Any] = ["kind": isMemoryServer(sv) ? "memory" : "tool", "text": "\(zh ? "用了" : "Used") \(sv.name)：\(tool)"]
            return .init(result: r.text.isEmpty ? "好了" : r.text, card: card)
        } catch {
            mark(sv.id, error)
            return .init(result: "没成：\(sv.name) 连不上", card: nil)
        }
    }

    /// 每轮聊之前：新对话或隔了 6 小时先 wake；每轮拿用户刚说的 recall。3 秒没回就算了。
    func memoryContext(_ host: LocalHost, companion: [String: Any], conversation: String, userText: String, incognito: Bool) async -> String {
        guard !incognito, let sv = memoryServer(host.store, companion: companion), let c = client(sv) else { return "" }
        let st = companion["settings"] as? [String: Any] ?? [:]
        var parts: [String] = []
        let needWake = lock.withLock { lastWake[conversation].map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true }
        if needWake {
            do {
                let w = try await c.call("wake", argumentsJSON: "{}", timeout: 3)
                lock.withLock { lastWake[conversation] = Date() }
                if !w.isError, !w.text.isEmpty { parts.append("〔记忆库 · 醒来〕\n\(w.text)") }
            } catch { mark(sv.id, error) }
        }
        let level = st["recall_level"] as? String ?? "medium"
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if level != "off", !text.isEmpty {
            let args = (try? JSONSerialization.data(withJSONObject: ["text": String(text.suffix(1000)), "level": level]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            do {
                let r = try await c.call("recall", argumentsJSON: args, timeout: 3)
                if !r.isError, !r.text.isEmpty { parts.append("〔记忆浮上来〕\n\(r.text)") }
            } catch { mark(sv.id, error) }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 路由（Me →「MCP 服务」）

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        guard p.first == "mcp", p.count >= 2, p[1] == "servers" else { return nil }
        let m = host.mcp, s = host.store
        switch (r.method, p.count) {
        case ("GET", 2):
            var out: [[String: Any]] = []
            for sv in m.servers(s) {
                let memory = (try? await m.tools(sv)).map(m.isMemory) ?? m.isMemoryServer(sv)
                out.append(["id": sv.id, "name": sv.name, "url": sv.url, "slug": sv.slug, "has_key": m.vault.get(sv.id) != nil,
                            "status": m.status(sv.id) ?? NSNull(), "memory": memory])
            }
            return .json(out)
        case ("POST", 2):
            let name = (r.json["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let url = (r.json["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .error(400, String(localized: "起个名字")) }
            guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? ""), u.host != nil else {
                return .error(400, String(localized: "地址要以 https:// 开头"))
            }
            let all = s.collection("mcp_servers")
            let id = UUID().uuidString.lowercased()
            var slug = MCPToolNames.slug(name, fallbackIndex: all.count + 1)
            if all.contains(where: { ($0["slug"] as? String) == slug }) { slug += "\(all.count + 1)" }
            s.saveCollection("mcp_servers", all + [["id": id, "name": name, "url": url, "slug": slug]])
            if let t = r.json["token"] as? String, !t.isEmpty { m.vault.set(t.trimmingCharacters(in: .whitespacesAndNewlines), for: id) }
            return .json(["id": id, "name": name, "url": url, "slug": slug], status: 201)
        case ("PATCH", 3):
            var all = s.collection("mcp_servers")
            guard let i = all.firstIndex(where: { ($0["id"] as? String) == p[2] }) else { return .error(404, String(localized: "没有这个服务")) }
            for k in ["name", "url"] { if let v = r.json[k] as? String, !v.isEmpty { all[i][k] = v.trimmingCharacters(in: .whitespacesAndNewlines) } }
            s.saveCollection("mcp_servers", all)
            if let t = r.json["token"] as? String { m.vault.set(t.isEmpty ? nil : t.trimmingCharacters(in: .whitespacesAndNewlines), for: p[2]) }
            m.forget(p[2])
            return .json(all[i])
        case ("DELETE", 3):
            s.saveCollection("mcp_servers", s.collection("mcp_servers").filter { ($0["id"] as? String) != p[2] })
            m.vault.set(nil, for: p[2]); m.forget(p[2])
            for var c in s.companions {   // TA 设定里的引用一起清掉
                var st = c["settings"] as? [String: Any] ?? [:]
                st["mcp_servers"] = (st["mcp_servers"] as? [String] ?? []).filter { $0 != p[2] }
                if st["memory_server"] as? String == p[2] { st["memory_server"] = NSNull() }
                c["settings"] = st; s.saveCompanion(c)
            }
            return .json(["ok": true])
        case ("POST", 4) where p[3] == "test":
            guard let sv = m.servers(s).first(where: { $0.id == p[2] }) else { return .error(404, String(localized: "没有这个服务")) }
            m.forget(sv.id)
            do {
                let t = try await m.tools(sv, fresh: true)
                return .json(["ok": true, "tools": t.map(\.name), "memory": m.isMemory(t)])
            } catch MCPError.unauthorized {
                return .json(["ok": false, "detail": String(localized: "钥匙不对")])
            } catch {
                return .json(["ok": false, "detail": String(localized: "连不上，看看地址对不对、服务开着没")])
            }
        case ("GET", 4) where p[3] == "web":
            // 记忆库软件 / 星图小组件用：网页地址 + 钥匙（只在手机里转一手，不出手机）
            guard let sv = m.servers(s).first(where: { $0.id == p[2] }) else { return .error(404, String(localized: "没有这个服务")) }
            return .json(["base": webBase(sv.url), "token": m.vault.get(sv.id) ?? ""])
        default:
            return nil
        }
    }

    /// 记忆库网页的地址 = MCP 地址去掉结尾的 /mcp（或链接模式的 /mcp/<secret>）
    static func webBase(_ url: String) -> String {
        var u = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let r = u.range(of: "/mcp", options: .backwards) { u = String(u[..<r.lowerBound]) }
        return u
    }
}
#endif
