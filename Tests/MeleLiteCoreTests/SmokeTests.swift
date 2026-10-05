import Foundation
import Testing
@testable import MeleLiteCore

/// 真 key 冒烟测试：只在本机、只在环境变量里有 key 时跑（MELE_SMOKE_ANTHROPIC / _DEEPSEEK / _GEMINI）。会花一点点钱。
private let env = ProcessInfo.processInfo.environment

private func say(_ cfg: ProviderConfig, _ key: String) async throws -> (String, String) {
    var c = sampleContact(); c.provider = cfg
    let req = Prompt.build(PromptInput(contact: c, identity: c.mainIdentity,
                                       history: [Message(role: .user, text: "刚下课，好累")], lang: .zh))
    let (t, th) = try await collect(makeClient(cfg, key: key).stream(req))
    print("【\(cfg.kind.rawValue) \(cfg.model)】思考 \(th.count) 字｜回复：\(t)")
    return (t, th)
}

@Suite(.serialized) struct SmokeTests {
    @Test(.enabled(if: env["MELE_SMOKE_ANTHROPIC"] != nil))
    func anthropic() async throws {
        let (t, _) = try await say(ProviderConfig(kind: .anthropic, model: env["MELE_SMOKE_ANTHROPIC_MODEL"] ?? "claude-sonnet-5", thinking: true),
                                   env["MELE_SMOKE_ANTHROPIC"]!)
        #expect(!t.isEmpty)
    }

    @Test(.enabled(if: env["MELE_SMOKE_DEEPSEEK"] != nil))
    func deepseek() async throws {
        let (t, _) = try await say(ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash"),
                                   env["MELE_SMOKE_DEEPSEEK"]!)
        #expect(!t.isEmpty)
    }

    @Test(.enabled(if: env["MELE_SMOKE_GEMINI"] != nil))
    func geminiAndSticker() async throws {
        let cfg = ProviderConfig(kind: .gemini, model: "gemini-3.5-flash-lite")
        let (t, _) = try await say(cfg, env["MELE_SMOKE_GEMINI"]!)
        #expect(!t.isEmpty)
        if let path = env["MELE_SMOKE_IMAGE"], let img = FileManager.default.contents(atPath: path) {
            let lib = StickerLibrary(root: tempRoot())
            let s = try lib.add(img)
            let c = try await lib.caption(s, using: makeClient(cfg, key: env["MELE_SMOKE_GEMINI"]!), lang: .zh)
            print("【表情包描述】\(c.caption)")
            #expect(!c.caption.isEmpty)
        }
    }
}

/// 真 key 试工具：DeepSeek 记一笔账 → 把结果递回去 → 它接着说话（MELE_SMOKE_DEEPSEEK）
@Suite(.serialized) struct ToolSmokeTests {
    @Test(.enabled(if: env["MELE_SMOKE_DEEPSEEK"] != nil))
    func deepseekToolRoundTrip() async throws {
        let cfg = ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let tool = ToolSpec(name: "wallet_add", description: "帮 TA 记一笔账（支出或收入）。TA 说了花了多少钱时用。",
                            parametersJSON: #"{"type":"object","properties":{"amount":{"type":"string"},"category":{"type":"string"},"note":{"type":"string"}},"required":["amount","category"]}"#)
        var req = ChatRequest(system: "你是 TA 的朋友，说话简短。你有工具能帮 TA 记账，TA 提到花钱时想用就用，用完照样跟 TA 说话。",
                              turns: [ChatTurn(role: .user, text: "午饭吃了拉面，花了 25 块")], maxTokens: 800, tools: [tool])
        let client = makeClient(cfg, key: env["MELE_SMOKE_DEEPSEEK"]!)
        var calls: [ToolCall] = [], raw: String?, said = ""
        for try await e in client.stream(req) {
            switch e {
            case .toolCall(let c): calls.append(c)
            case .assistantRaw(let r): raw = r
            case .text(let t): said += t
            default: break
            }
        }
        print("【DeepSeek 工具】第一轮说：\(said)｜调用：\(calls.map { "\($0.name) \($0.argumentsJSON)" })")
        #expect(calls.first?.name == "wallet_add")
        req.turns.append(ChatTurn(role: .assistant, text: said, toolCalls: calls, raw: raw))
        req.turns.append(ChatTurn(role: .user, text: "", toolResults: calls.map { ToolResult(id: $0.id, name: $0.name, content: "记好了：吃饭 ¥25 · 拉面") }))
        var after = ""
        for try await e in client.stream(req) { if case .text(let t) = e { after += t } }
        print("【DeepSeek 工具】第二轮说：\(after)")
        #expect(!after.isEmpty)
    }
}
