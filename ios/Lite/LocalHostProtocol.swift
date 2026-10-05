#if LITE
import Foundation

/// 把发往 http://mele.local/… 的请求拦下来交给手机里的小管家（LocalHost），不出手机。
/// 事件流（text/event-stream）一块块往回吐，跟真服务器一样。
final class LocalHostProtocol: URLProtocol, @unchecked Sendable {
    static let host = "mele.local"
    static var baseURL: URL { URL(string: "http://\(host)")! }

    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let body = Self.body(of: req)
        work = Task { [weak self] in
            let res = await LocalHost.shared.handle(LocalRequest(request: req, body: body))
            guard let self, !Task.isCancelled else { return }
            switch res {
            case .stream(let chunks):
                self.respond(200, mime: "text/event-stream")
                for await chunk in chunks {
                    if Task.isCancelled { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            default:
                let (status, mime, data) = res.payload
                self.respond(status, mime: mime)
                if !data.isEmpty { self.client?.urlProtocol(self, didLoad: data) }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        work?.cancel()
        work = nil
    }

    private func respond(_ status: Int, mime: String) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
    }

    /// URLSession 把 httpBody 换成了 stream，这里读回来
    private static func body(of req: URLRequest) -> Data {
        if let d = req.httpBody { return d }
        guard let s = req.httpBodyStream else { return Data() }
        s.open()
        defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

/// 进来的一个请求，拆好方便路由用
struct LocalRequest {
    let method: String
    let parts: [String]                 // 路径按 / 切开
    let query: [String: String]
    let body: Data

    init(request: URLRequest, body: Data) {
        method = request.httpMethod ?? "GET"
        let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        parts = (comps?.path ?? "").split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        query = q
        self.body = body
        contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
    }

    let contentType: String

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }

    /// multipart/form-data：字段 + 文件（字段名 → [(文件名, 数据)]）
    var form: (fields: [String: String], files: [String: [(name: String, data: Data)]]) {
        guard let b = contentType.components(separatedBy: "boundary=").last, contentType.contains("multipart") else { return ([:], [:]) }
        let boundary = Data("--\(b)".utf8)
        var fields: [String: String] = [:]
        var files: [String: [(String, Data)]] = [:]
        var chunks: [Data] = []
        var rest = body[...]
        while let r = rest.range(of: boundary) {
            let piece = rest[rest.startIndex..<r.lowerBound]
            if !piece.isEmpty { chunks.append(Data(piece)) }
            rest = rest[r.upperBound...]
        }
        for chunk in chunks {
            guard let split = chunk.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: chunk[chunk.startIndex..<split.lowerBound], as: UTF8.self)
            var content = Data(chunk[split.upperBound...])
            if content.suffix(2) == Data("\r\n".utf8) { content.removeLast(2) }
            guard let name = Self.attr("name", in: head) else { continue }
            if let fileName = Self.attr("filename", in: head) {
                files[name, default: []].append((fileName, content))
            } else {
                fields[name] = String(decoding: content, as: UTF8.self)
            }
        }
        return (fields, files)
    }

    private static func attr(_ key: String, in head: String) -> String? {
        guard let r = head.range(of: "\(key)=\"") else { return nil }
        let after = head[r.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }
}

/// 小管家的回答
enum LocalResponse {
    case json(Any, status: Int = 200)
    case data(Data, mime: String)
    case empty                          // 204
    case error(Int, String)             // {"detail": "…"}
    case stream(AsyncStream<Data>)

    /// 管家答不了：要连上 Mele Host 才有
    static var needsHost: LocalResponse { .error(503, String(localized: "这个功能要连上 Mele Host 才能用")) }

    var payload: (Int, String, Data) {
        switch self {
        case .json(let v, let status):
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            return (status, "application/json", d)
        case .data(let d, let mime): return (200, mime, d)
        case .empty: return (204, "application/json", Data())
        case .error(let status, let detail):
            let d = (try? JSONSerialization.data(withJSONObject: ["detail": detail, "needs_host": status == 503])) ?? Data()
            return (status, "application/json", d)
        case .stream: return (200, "text/event-stream", Data())
        }
    }
}
#endif
