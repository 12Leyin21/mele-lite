import Foundation

/// OpenAI 兼容的 /chat/completions（OpenAI、DeepSeek、OpenRouter…）。DeepSeek 的 reasoning_content 当思考。
/// 工具：function calling；tool_calls 一截一截按 index 攒，结束时一起吐。用工具那一轮的 reasoning_content 留着原样递回（DeepSeek 要）。
struct OpenAIClient: LLMClient {
    let config: ProviderConfig
    let key: String
    let session: URLSession

    var endpoint: URL {
        var base = (config.baseURL?.isEmpty == false ? config.baseURL! : "https://api.openai.com/v1")
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/chat/completions")!
    }

    func body(_ r: ChatRequest) -> [String: Any] {
        // 这几家的缓存是自动的（前缀一样就命中）：每轮变的 context 贴在 TA 最新那句后面，前面才稳
        var msgs: [[String: Any]] = [["role": "system", "content": r.contextIndex == nil && !r.context.isEmpty ? r.system + "\n\n" + r.context : r.system]]
        for (i, t0) in r.turns.enumerated() {
            var t = t0
            if i == r.contextIndex, !r.context.isEmpty { t.text += (t.text.isEmpty ? "" : "\n\n") + r.context }
            if !t.toolResults.isEmpty {
                for res in t.toolResults { msgs.append(["role": "tool", "tool_call_id": res.id, "content": res.content]) }
                if t.text.isEmpty && t.imageJPEG == nil { continue }
            }
            if t.role == .assistant && !t.toolCalls.isEmpty {
                var m: [String: Any] = ["role": "assistant", "content": t.text.isEmpty ? NSNull() : t.text,
                                        "tool_calls": t.toolCalls.map { ["id": $0.id, "type": "function",
                                                                         "function": ["name": $0.name, "arguments": $0.argumentsJSON]] }]
                if let raw = t.raw, let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                   let rc = o["reasoning_content"] as? String, !rc.isEmpty {
                    m["reasoning_content"] = rc
                }
                msgs.append(m)
                continue
            }
            if let img = t.imageJPEG {
                msgs.append(["role": t.role.rawValue, "content": [
                    ["type": "text", "text": t.text],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]],
                ]])
            } else {
                msgs.append(["role": t.role.rawValue, "content": t.text])
            }
        }
        var b: [String: Any] = ["model": config.model, "messages": msgs, "stream": true, "max_tokens": r.maxTokens,
                                "stream_options": ["include_usage": true]]      // 最后一截带用量（用量页 / 水位）
        // DeepSeek 不说就默认想（10-05 真 key：手写独白时它还是交一大段英文分析腔、把独白顶掉）。服务器 openai_adapter 也这么带
        if endpoint.host?.contains("deepseek") == true {
            b["thinking"] = ["type": config.thinking ? "enabled" : "disabled"]
        }
        if !r.tools.isEmpty {
            b["tools"] = r.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
        }
        return b
    }

    func stream(_ r: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body(r), options: [.sortedKeys])   // 键顺序固定：Swift 字典每次排法不一样，工具说明一变前缀就对不上、缓存全丢（10-08 Tilia：命中只有两三成）
        let st = StreamState()
        return HTTPStream.run(req, session: session, model: config.model, state: st, parse: { payload in
            if payload == "[DONE]" { return [.done(nil)] }
            let o = try HTTPStream.json(payload)
            if let e = o["error"] as? [String: Any] { throw LLMError.server(e["message"] as? String ?? "error") }
            if let u = o["usage"] as? [String: Any] {
                // OpenAI：prompt_tokens_details.cached_tokens；DeepSeek：prompt_cache_hit_tokens
                let prompt = u["prompt_tokens"] as? Int ?? 0
                let hit = ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? (u["prompt_cache_hit_tokens"] as? Int) ?? 0
                st.lock.withLock { st.usage = Usage(input: max(0, prompt - hit), output: u["completion_tokens"] as? Int ?? 0, cacheRead: hit) }
            }
            var out: [StreamEvent] = []
            for c in o["choices"] as? [[String: Any]] ?? [] {
                let d = c["delta"] as? [String: Any] ?? [:]
                if let th = d["reasoning_content"] as? String, !th.isEmpty {
                    st.lock.withLock { st.reasoning += th }
                    out.append(.thinking(th))
                }
                if let tx = d["content"] as? String, !tx.isEmpty { out.append(.text(tx)) }
                for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
                    let i = tc["index"] as? Int ?? 0
                    let f = tc["function"] as? [String: Any] ?? [:]
                    st.lock.withLock {
                        var cur = st.calls[i] ?? (id: "", name: "", args: "")
                        if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                        if let n = f["name"] as? String, !n.isEmpty { cur.name = n }
                        cur.args += f["arguments"] as? String ?? ""
                        st.calls[i] = cur
                    }
                }
                if (c["finish_reason"] as? String) == "content_filter" { throw LLMError.refused }
            }
            return out
        }, finish: {
            st.lock.withLock {
                var out: [StreamEvent] = st.calls.keys.sorted().map { i in
                    let c = st.calls[i]!
                    return .toolCall(ToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, argumentsJSON: c.args.isEmpty ? "{}" : c.args))
                }
                if !out.isEmpty { out.append(.assistantRaw(HTTPStream.string(["reasoning_content": st.reasoning]))) }
                return out
            }
        })
    }
}
