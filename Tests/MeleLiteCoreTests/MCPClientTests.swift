import Foundation
import Testing
@testable import MeleLiteCore

/// 按 method 回话的假 MCP 服务器。每个测试一个 token（请求头 x-stub），互不干扰。
final class MCPStub: URLProtocol, @unchecked Sendable {
    struct Script { var sse = false; var status401 = false; var expireOnce = false }
    nonisolated(unsafe) static var scripts: [String: Script] = [:]
    nonisolated(unsafe) static var seen: [String: [(method: String, session: String?)]] = [:]
    nonisolated(unsafe) static var expired: Set<String> = []
    static let lock = NSLock()

    static func session(_ token: String, _ s: Script) -> URLSession {
        lock.withLock { scripts[token] = s; seen[token] = [] }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MCPStub.self]
        cfg.httpAdditionalHeaders = ["x-stub": token]
        return URLSession(configuration: cfg)
    }
    static func methods(_ token: String) -> [(method: String, session: String?)] { lock.withLock { seen[token] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "x-stub") ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        let msg = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let method = msg["method"] as? String ?? ""
        let sid = request.value(forHTTPHeaderField: "Mcp-Session-Id")
        let script = Self.lock.withLock { () -> Script in
            Self.seen[token, default: []].append((method, sid))
            return Self.scripts[token] ?? Script()
        }
        func send(_ status: Int, _ headers: [String: String], _ text: String) {
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if script.status401 { send(401, [:], "unauthorized"); return }
        if method == "notifications/initialized" { send(202, [:], ""); return }
        if method != "initialize", script.expireOnce, Self.lock.withLock({ Self.expired.insert(token).inserted }) {
            send(404, [:], "session gone"); return
        }
        let id = msg["id"] ?? NSNull()
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "stub", "version": "1"]]
        case "tools/list":
            result = ["tools": [["name": "recall", "description": "想起来",
                                 "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]]]]
        case "tools/call":
            let args = (msg["params"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
            result = ["content": [["type": "text", "text": "想起：\(args["text"] ?? "")"]], "structuredContent": ["n": 1], "isError": false]
        default:
            result = [:]
        }
        let reply = String(data: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]), encoding: .utf8)!
        var headers = ["mcp-session-id": "s-\(token.prefix(4))"]
        if script.sse {
            headers["content-type"] = "text/event-stream"
            send(200, headers, "event: message\ndata: \(reply)\n\n")
        } else {
            headers["content-type"] = "application/json"
            send(200, headers, reply)
        }
    }
}

@Suite struct MCPClientTests {
    let url = URL(string: "http://stub.local/mcp")!

    @Test(arguments: [false, true]) func handshakeListAndCall(sse: Bool) async throws {
        let t = UUID().uuidString
        let c = MCPClient(url: url, token: "k", session: MCPStub.session(t, .init(sse: sse)))
        let tools = try await c.listTools()
        #expect(tools.map(\.name) == ["recall"])
        #expect(tools[0].inputSchemaJSON.contains("\"text\""))
        let r = try await c.call("recall", argumentsJSON: #"{"text":"芒果"}"#)
        #expect(r.text == "想起：芒果")
        #expect(r.structured?["n"] as? Int == 1)
        #expect(!r.isError)
        let m = MCPStub.methods(t)
        #expect(m.map(\.method) == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        #expect(m[0].session == nil)
        #expect(m[2].session == "s-\(t.prefix(4))")
    }

    @Test func unauthorized() async {
        let t = UUID().uuidString
        let c = MCPClient(url: url, token: "bad", session: MCPStub.session(t, .init(status401: true)))
        await #expect(throws: MCPError.unauthorized) { try await c.listTools() }
    }

    @Test func expiredSessionReHandshakesOnce() async throws {
        let t = UUID().uuidString
        let c = MCPClient(url: url, token: "k", session: MCPStub.session(t, .init(expireOnce: true)))
        let tools = try await c.listTools()
        #expect(tools.count == 1)
        #expect(MCPStub.methods(t).map(\.method) == ["initialize", "notifications/initialized", "tools/list",
                                                    "initialize", "notifications/initialized", "tools/list"])
    }
}

private let env = ProcessInfo.processInfo.environment

/// 对着本机的 mele-memory 跑（launch.json 里的 mele-memory-web，8767，假向量）：
/// MELE_MEMORY_TEST_URL=http://localhost:8767/mcp MELE_MEMORY_TEST_TOKEN=… swift test --filter MCPLive
@Suite(.serialized) struct MCPLive {
    @Test(.enabled(if: env["MELE_MEMORY_TEST_URL"] != nil))
    func meleMemoryRoundTrip() async throws {
        let c = MCPClient(url: URL(string: env["MELE_MEMORY_TEST_URL"]!)!, token: env["MELE_MEMORY_TEST_TOKEN"])
        let names = Set(try await c.listTools().map(\.name))
        #expect(names.isSuperset(of: ["wake", "recall", "person_upsert", "remember"]))
        let saved = try await c.call("remember", argumentsJSON: #"{"content":"小满对芒果过敏","title":"芒果过敏","importance":8}"#)
        #expect(!saved.isError, "\(saved.text)")
        let r = try await c.call("recall", argumentsJSON: #"{"text":"小满能吃芒果冰沙吗"}"#)
        #expect(!r.isError)
        print("recall →", r.text)
    }
}
