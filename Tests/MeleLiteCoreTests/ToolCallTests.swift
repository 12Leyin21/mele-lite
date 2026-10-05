import Foundation
import Testing
@testable import MeleLiteCore

private let walletTool = ToolSpec(name: "wallet_add", description: "记一笔账",
                                  parametersJSON: #"{"type":"object","properties":{"amount":{"type":"string"}},"required":["amount"]}"#)

private func events(_ s: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var out: [StreamEvent] = []
    for try await e in s { out.append(e) }
    return out
}

@Suite struct ToolCallTests {
    @Test func anthropicToolUseRoundTrip() async throws {
        let sse = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"记一下"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"wallet_add","input":{}}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"amount\\":"}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"25\\"}"}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"message_stop"}

        """
        let token = UUID().uuidString
        let client = makeClient(ProviderConfig(kind: .anthropic, model: "claude-sonnet-5", thinking: true), key: "k",
                                session: StubProtocol.session(token: token, reply: .init(status: 200, body: sse)))
        let evs = try await events(client.stream(ChatRequest(system: "", turns: [ChatTurn(role: .user, text: "午饭 25")], tools: [walletTool])))
        let call = evs.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }.first
        #expect(call == ToolCall(id: "tu_1", name: "wallet_add", argumentsJSON: #"{"amount":"25"}"#))
        let raw = evs.compactMap { if case .assistantRaw(let r) = $0 { r } else { nil } }.first ?? ""
        #expect(raw.contains("sig1") && raw.contains("tool_use"))
        let tools = StubProtocol.bodyJSON(token)["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "wallet_add")
        #expect((tools?.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")

        // 第二轮：它那一轮原样递回去，工具结果用 tool_result
        let token2 = UUID().uuidString
        let client2 = makeClient(ProviderConfig(kind: .anthropic, model: "claude-sonnet-5", thinking: true), key: "k",
                                 session: StubProtocol.session(token: token2, reply: .init(status: 200, body: "data: {\"type\":\"message_stop\"}\n")))
        let turns = [ChatTurn(role: .user, text: "午饭 25"),
                     ChatTurn(role: .assistant, text: "", toolCalls: [call!], raw: raw),
                     ChatTurn(role: .user, text: "", toolResults: [ToolResult(id: "tu_1", name: "wallet_add", content: "记好了")])]
        _ = try await events(client2.stream(ChatRequest(system: "", turns: turns, tools: [walletTool])))
        let msgs = StubProtocol.bodyJSON(token2)["messages"] as? [[String: Any]] ?? []
        let asst = msgs[1]["content"] as? [[String: Any]] ?? []
        #expect(asst.first?["type"] as? String == "thinking")
        #expect(asst.first?["signature"] as? String == "sig1")
        let result = (msgs[2]["content"] as? [[String: Any]])?.first
        #expect(result?["type"] as? String == "tool_result")
        #expect(result?["tool_use_id"] as? String == "tu_1")
    }

    @Test func openAIToolCallsAccumulate() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"想一下"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"wallet_add","arguments":"{\\"amo"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"unt\\":\\"25\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let token = UUID().uuidString
        let cfg = ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let client = makeClient(cfg, key: "k", session: StubProtocol.session(token: token, reply: .init(status: 200, body: sse)))
        let evs = try await events(client.stream(ChatRequest(system: "s", turns: [ChatTurn(role: .user, text: "午饭 25")], tools: [walletTool])))
        let call = evs.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }.first
        #expect(call == ToolCall(id: "call_9", name: "wallet_add", argumentsJSON: #"{"amount":"25"}"#))
        let tools = StubProtocol.bodyJSON(token)["tools"] as? [[String: Any]]
        #expect((tools?.first?["function"] as? [String: Any])?["name"] as? String == "wallet_add")
        let raw = evs.compactMap { if case .assistantRaw(let r) = $0 { r } else { nil } }.first ?? ""

        let token2 = UUID().uuidString
        let client2 = makeClient(cfg, key: "k", session: StubProtocol.session(token: token2, reply: .init(status: 200, body: "data: [DONE]\n")))
        _ = try await events(client2.stream(ChatRequest(system: "s", turns: [
            ChatTurn(role: .user, text: "午饭 25"),
            ChatTurn(role: .assistant, text: "", toolCalls: [call!], raw: raw),
            ChatTurn(role: .user, text: "", toolResults: [ToolResult(id: "call_9", name: "wallet_add", content: "记好了")]),
        ], tools: [walletTool])))
        let msgs = StubProtocol.bodyJSON(token2)["messages"] as? [[String: Any]] ?? []
        #expect(msgs[2]["role"] as? String == "assistant")
        #expect(((msgs[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String) == "call_9")
        #expect(msgs[2]["reasoning_content"] as? String == "想一下")
        #expect(msgs[3]["role"] as? String == "tool")
        #expect(msgs[3]["tool_call_id"] as? String == "call_9")
    }

    @Test func geminiFunctionCall() async throws {
        let sse = """
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"wallet_add","args":{"amount":"25"}},"thoughtSignature":"gsig"}]}}]}

        """
        let token = UUID().uuidString
        let cfg = ProviderConfig(kind: .gemini, model: "gemini-3.5-flash", thinking: true)
        let client = makeClient(cfg, key: "k", session: StubProtocol.session(token: token, reply: .init(status: 200, body: sse)))
        let evs = try await events(client.stream(ChatRequest(system: "s", turns: [ChatTurn(role: .user, text: "午饭 25")], tools: [walletTool])))
        let call = evs.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }.first
        #expect(call?.name == "wallet_add")
        #expect(call?.argumentsJSON == #"{"amount":"25"}"#)
        let decl = ((StubProtocol.bodyJSON(token)["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])?.first
        #expect(decl?["name"] as? String == "wallet_add")
        let raw = evs.compactMap { if case .assistantRaw(let r) = $0 { r } else { nil } }.first ?? ""

        let token2 = UUID().uuidString
        let client2 = makeClient(cfg, key: "k", session: StubProtocol.session(token: token2, reply: .init(status: 200, body: "")))
        _ = try await events(client2.stream(ChatRequest(system: "s", turns: [
            ChatTurn(role: .user, text: "午饭 25"),
            ChatTurn(role: .assistant, text: "", toolCalls: [call!], raw: raw),
            ChatTurn(role: .user, text: "", toolResults: [ToolResult(id: call!.id, name: "wallet_add", content: "记好了")]),
        ], tools: [walletTool])))
        let contents = StubProtocol.bodyJSON(token2)["contents"] as? [[String: Any]] ?? []
        let modelParts = contents[1]["parts"] as? [[String: Any]] ?? []
        #expect(modelParts.first?["thoughtSignature"] as? String == "gsig")
        let resp = ((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])
        #expect(resp?["name"] as? String == "wallet_add")
    }
}
