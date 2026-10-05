import Foundation

/// 给模型的一个工具：名字、一句说明、参数的 JSON Schema（原样字符串，三家各自包一层）
public struct ToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }
    var parameters: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8)) as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
    }
}

/// 它要用一次工具（参数是一段 JSON 字符串）
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) { self.id = id; self.name = name; self.argumentsJSON = argumentsJSON }
    public var arguments: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
    }
}

/// 工具跑完的结果，递回给它
public struct ToolResult: Equatable, Sendable {
    public var id: String
    public var name: String
    public var content: String
    public init(id: String, name: String, content: String) { self.id = id; self.name = name; self.content = content }
}

public struct ChatTurn: Equatable, Sendable {
    public var role: Role
    public var text: String
    public var imageJPEG: Data?
    /// 它这一轮要用的工具（assistant）
    public var toolCalls: [ToolCall]
    /// 工具结果（user 那一侧递回去）
    public var toolResults: [ToolResult]
    /// 它这一轮的原样内容（各家自己的格式：Claude 的思考签名、Gemini 的 thoughtSignature、DeepSeek 的 reasoning_content），用工具时要原样递回去
    public var raw: String?
    public init(role: Role, text: String, imageJPEG: Data? = nil, toolCalls: [ToolCall] = [], toolResults: [ToolResult] = [], raw: String? = nil) {
        self.role = role; self.text = text; self.imageJPEG = imageJPEG
        self.toolCalls = toolCalls; self.toolResults = toolResults; self.raw = raw
    }
}

public struct ChatRequest: Equatable, Sendable {
    /// 不常变的：底子、人设、对面这个人、线上线下、表情包、工具说明——放最前面，好让缓存吃得住
    public var system: String
    public var turns: [ChatTurn]
    public var maxTokens: Int
    public var tools: [ToolSpec]
    /// 每轮都会变的（几点、世界书命中、翻到的、它此刻在哪、TA 那边……）：发的时候贴在 TA 最新那句后面，
    /// 不放进 system——放进去的话它后面的整段历史每轮都得重算（10-04）
    public var context: String
    public init(system: String, turns: [ChatTurn], maxTokens: Int = 16000, tools: [ToolSpec] = [], context: String = "") {
        self.system = system; self.turns = turns; self.maxTokens = maxTokens; self.tools = tools; self.context = context
    }

    /// TA 最新那句（有字或有图的 user 轮，不算只装工具结果的那种）在 turns 里的位置；context 贴在它上面
    public var contextIndex: Int? {
        turns.lastIndex { $0.role == .user && (!$0.text.isEmpty || $0.imageJPEG != nil) }
    }
}

/// 一次调用用了多少（10-04 用量页 / 水位）：input = 没命中缓存的输入；cacheRead = 命中缓存的；cacheWrite = 这次新写进缓存的（只有 Claude 报）
public struct Usage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public init(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    /// 这次喂给模型的总量（水位用）
    public var prompt: Int { input + cacheRead + cacheWrite }
}

/// 每次调用完报一声用了多少（App 那边接上记账）。三家都走这里，聊天、写日记、解塔罗……一个不漏。
public enum UsageMeter {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var sink: (@Sendable (String, Usage) -> Void)?
    }
    private static let box = Box()
    public static func setSink(_ f: @escaping @Sendable (_ model: String, _ usage: Usage) -> Void) { box.lock.withLock { box.sink = f } }
    static func report(_ model: String, _ u: Usage) { box.lock.withLock { box.sink }?(model, u) }
}

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolCall(ToolCall)
    /// 这一轮它说的原样内容（流结束前给一次），用了工具时下一轮要原样递回去
    case assistantRaw(String)
    case done(Usage?)
}

/// 一轮流式里要攒着的东西（工具参数是一截一截来的、Claude 的思考签名、DeepSeek 的 reasoning_content）
final class StreamState: @unchecked Sendable {
    let lock = NSLock()
    var blocks: [[String: Any]] = []          // Claude：这一轮的内容块（按出现顺序）
    var open: [Int: [String: Any]] = [:]      // Claude：还没收尾的块（index → 块）
    var calls: [Int: (id: String, name: String, args: String)] = [:]   // OpenAI：按 index 攒
    var reasoning = ""
    var text = ""
    var parts: [[String: Any]] = []           // Gemini：模型那一轮的 parts（带 thoughtSignature）
    var flushed = false
    var usage: Usage?                         // 三家各自报的用量，结束时随 .done 一起吐
}

public enum LLMError: Error, Equatable, Sendable {
    case auth          // key 不对
    case quota         // 限流 / 余额
    case network       // 连不上、中途断
    case refused       // 模型拒答
    case server(String)
    case badResponse
}

public protocol LLMClient: Sendable {
    func stream(_ r: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public func makeClient(_ c: ProviderConfig, key: String, session: URLSession = .shared) -> LLMClient {
    switch c.kind {
    case .anthropic: return AnthropicClient(config: c, key: key, session: session)
    case .openai: return OpenAIClient(config: c, key: key, session: session)
    case .gemini: return GeminiClient(config: c, key: key, session: session)
    }
}

/// 三家共用：发请求、看状态码、逐行把 `data:` 交给 parse。parse 返回要吐出去的事件，`nil` 表示这行没东西。
enum HTTPStream {
    static func run(_ req: URLRequest, session: URLSession, model: String = "", state: StreamState? = nil,
                    parse: @escaping @Sendable (String) throws -> [StreamEvent],
                    finish: @escaping @Sendable () -> [StreamEvent] = { [] }) -> AsyncThrowingStream<StreamEvent, Error> {
        // .done 带上这一轮的用量，顺手报给 UsageMeter
        @Sendable func done(_ e: StreamEvent) -> StreamEvent {
            guard case .done(let given) = e else { return e }
            let u = given ?? state?.lock.withLock { state?.usage }
            if let u { UsageMeter.report(model, u) }
            return .done(u)
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                        throw errorFor(status: status, body: body)
                    }
                    var finished = false
                    for try await line in bytes.lines {
                        guard let payload = SSE.data(line) else { continue }
                        for e in try parse(payload) {
                            if case .done = e {
                                if !finished { for f in finish() { cont.yield(f) } }
                                if finished { continue }
                                finished = true
                                cont.yield(done(e))
                                continue
                            }
                            cont.yield(e)
                        }
                    }
                    if !finished { for f in finish() { cont.yield(f) }; cont.yield(done(.done(nil))) }
                    cont.finish()
                } catch let e as LLMError {
                    cont.finish(throwing: e)
                } catch is CancellationError {
                    cont.finish(throwing: CancellationError())
                } catch {
                    cont.finish(throwing: LLMError.network)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func errorFor(status: Int, body: String) -> LLMError {
        switch status {
        case 401, 403: return .auth
        case 402, 429: return .quota
        default: return .server("HTTP \(status): \(body.prefix(300))")
        }
    }

    static func string(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func json(_ s: String) throws -> [String: Any] {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw LLMError.badResponse
        }
        return o
    }
}
