import Foundation

/// MCP 小信差（Streamable HTTP）：拿着地址和钥匙去问对面有哪些工具、替 TA 调一次。
/// 每次都是 POST 一条 JSON-RPC；回来的可能是 JSON，也可能是 SSE（只取 id 对得上的那条）。
public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name; self.description = description; self.inputSchemaJSON = inputSchemaJSON
    }
}

public struct MCPCallResult: Equatable, Sendable {
    public var text: String
    public var structuredJSON: String?
    public var isError: Bool
    public init(text: String, structuredJSON: String?, isError: Bool) {
        self.text = text; self.structuredJSON = structuredJSON; self.isError = isError
    }
    public var structured: [String: Any]? {
        structuredJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

public enum MCPError: Error, Equatable {
    case unauthorized
    case http(Int)
    case rpc(Int, String)
    case badReply
    case timeout
}

public actor MCPClient {
    public static let protocolVersion = "2025-06-18"
    let url: URL
    let token: String?
    let session: URLSession
    private var sessionID: String?
    private var ready = false
    private var nextID = 1

    public init(url: URL, token: String?, session: URLSession = .shared) {
        self.url = url; self.token = token; self.session = session
    }

    public func listTools() async throws -> [MCPTool] {
        var out: [MCPTool] = []
        var cursor: String?
        repeat {
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let r = try await request("tools/list", params, timeout: 10)
            for t in r["tools"] as? [[String: Any]] ?? [] {
                guard let name = t["name"] as? String else { continue }
                let schema = t["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
                let json = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                out.append(MCPTool(name: name, description: t["description"] as? String ?? "", inputSchemaJSON: json))
            }
            cursor = r["nextCursor"] as? String
        } while cursor != nil
        return out
    }

    public func call(_ name: String, argumentsJSON: String, timeout: TimeInterval = 20) async throws -> MCPCallResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let r = try await request("tools/call", ["name": name, "arguments": args], timeout: timeout)
        let text = (r["content"] as? [[String: Any]] ?? [])
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        let structured = (r["structuredContent"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return MCPCallResult(text: text, structuredJSON: structured, isError: r["isError"] as? Bool ?? false)
    }

    // MARK: - 握手和收发

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if !ready { try await handshake() }
        do {
            return try await rpc(method, params, timeout: timeout)
        } catch MCPError.http(404) where sessionID != nil {
            // 会话过期（服务器重启过）：重新握手，只重试一次
            ready = false; sessionID = nil
            try await handshake()
            return try await rpc(method, params, timeout: timeout)
        }
    }

    private func handshake() async throws {
        _ = try await rpc("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Mele", "version": "1"],
        ], timeout: 10)
        try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], timeout: 10, expectReply: false)
        ready = true
    }

    private func rpc(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let reply = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], timeout: timeout, expectReply: true)
        guard let msg = reply.first(where: { ($0["id"] as? Int) == id }) else { throw MCPError.badReply }
        if let e = msg["error"] as? [String: Any] {
            throw MCPError.rpc(e["code"] as? Int ?? 0, e["message"] as? String ?? "")
        }
        guard let result = msg["result"] as? [String: Any] else { throw MCPError.badReply }
        return result
    }

    @discardableResult
    private func post(_ body: [String: Any], timeout: TimeInterval, expectReply: Bool) async throws -> [[String: Any]] {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw MCPError.timeout
        }
        guard let http = resp as? HTTPURLResponse else { throw MCPError.badReply }
        if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.http(http.statusCode) }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard expectReply else { return [] }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            // SSE：每个事件的 data 行拼起来是一条 JSON-RPC 消息
            var out: [[String: Any]] = []
            let normalized = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            for block in normalized.components(separatedBy: "\n\n") {
                let payload = block.split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { $0.hasPrefix("data:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] { out.append(obj) }
            }
            return out
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let one = obj as? [String: Any] { return [one] }
        if let many = obj as? [[String: Any]] { return many }
        throw MCPError.badReply
    }
}
