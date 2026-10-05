import Foundation
@testable import MeleLiteCore

/// 假服务器：每个测试用自己的 token 注册一个回应，请求头 x-stub 带着 token，互不干扰（测试是并行跑的）。
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var failMidway: Bool = false }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var captured: [String: URLRequest] = [:]
    static let lock = NSLock()

    static func session(token: String, reply: Reply) -> URLSession {
        lock.withLock { replies[token] = reply }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        cfg.httpAdditionalHeaders = ["x-stub": token]
        return URLSession(configuration: cfg)
    }

    static func request(_ token: String) -> URLRequest? { lock.withLock { captured[token] } }

    static func bodyJSON(_ token: String) -> [String: Any] {
        guard var r = request(token) else { return [:] }
        if r.httpBody == nil, let s = r.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); r.httpBody = d
        }
        return (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "x-stub") ?? ""
        let reply = Self.lock.withLock { () -> Reply? in
            Self.captured[token] = request
            return Self.replies[token]
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        if reply.failMidway {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

func collect(_ s: AsyncThrowingStream<StreamEvent, Error>) async throws -> (text: String, thinking: String) {
    var text = "", thinking = ""
    for try await e in s {
        switch e {
        case .text(let t): text += t
        case .thinking(let t): thinking += t
        case .done, .toolCall, .assistantRaw: break
        }
    }
    return (text, thinking)
}
