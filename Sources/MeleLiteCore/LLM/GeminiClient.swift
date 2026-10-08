import Foundation

/// Gemini :streamGenerateContent?alt=sse。parts 里 thought: true 的是思考。
/// 工具：functionDeclarations；functionCall 整块来。模型那一轮的 parts（带 thoughtSignature）原样留着，下一轮递回去。
struct GeminiClient: LLMClient {
    let config: ProviderConfig
    let key: String
    let session: URLSession

    func content(_ t: ChatTurn) -> [String: Any] {
        if t.role == .assistant, let raw = t.raw,
           let parts = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]], !parts.isEmpty {
            return ["role": "model", "parts": parts]
        }
        var parts: [[String: Any]] = []
        for r in t.toolResults {
            parts.append(["functionResponse": ["name": r.name, "response": ["content": r.content]]])
        }
        if let img = t.imageJPEG {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": img.base64EncodedString()]])
        }
        if !t.text.isEmpty || parts.isEmpty { parts.append(["text": t.text]) }
        for c in t.toolCalls { parts.append(["functionCall": ["name": c.name, "args": c.arguments]]) }
        return ["role": t.role == .user ? "user" : "model", "parts": parts]
    }

    func body(_ r: ChatRequest) -> [String: Any] {
        var b: [String: Any] = [
            "systemInstruction": ["parts": [["text": r.contextIndex == nil && !r.context.isEmpty ? r.system + "\n\n" + r.context : r.system]]],
            "contents": r.turns.enumerated().map { i, t0 in      // 每轮变的 context 贴在 TA 最新那句后面（隐式缓存吃前缀）
                var t = t0
                if i == r.contextIndex, !r.context.isEmpty, t.raw == nil { t.text += (t.text.isEmpty ? "" : "\n\n") + r.context }
                return content(t)
            },
        ]
        if !r.tools.isEmpty {
            b["tools"] = [["functionDeclarations": r.tools.map { ["name": $0.name, "description": $0.description, "parameters": GeminiSchema.clean($0.parameters)] }]]
        }
        var gen: [String: Any] = ["maxOutputTokens": r.maxTokens]
        if config.thinking { gen["thinkingConfig"] = ["includeThoughts": true] }
        b["generationConfig"] = gen
        return b
    }

    func stream(_ r: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let model = config.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.model
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body(r), options: [.sortedKeys])   // 键顺序固定：Swift 字典每次排法不一样，工具说明一变前缀就对不上、缓存全丢（10-08 Tilia：命中只有两三成）
        let st = StreamState()
        return HTTPStream.run(req, session: session, model: config.model, state: st, parse: { payload in
            let o = try HTTPStream.json(payload)
            if let e = o["error"] as? [String: Any] { throw LLMError.server(e["message"] as? String ?? "error") }
            if let u = o["usageMetadata"] as? [String: Any] {          // 每截都带，留最后一份
                let prompt = u["promptTokenCount"] as? Int ?? 0, hit = u["cachedContentTokenCount"] as? Int ?? 0
                let out = (u["candidatesTokenCount"] as? Int ?? 0) + (u["thoughtsTokenCount"] as? Int ?? 0)
                st.lock.withLock { st.usage = Usage(input: max(0, prompt - hit), output: out, cacheRead: hit) }
            }
            var out: [StreamEvent] = []
            for c in o["candidates"] as? [[String: Any]] ?? [] {
                if (c["finishReason"] as? String) == "SAFETY" { throw LLMError.refused }
                for p in (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
                    if let fc = p["functionCall"] as? [String: Any] {
                        st.lock.withLock { st.parts.append(p) }
                        out.append(.toolCall(ToolCall(id: (fc["id"] as? String) ?? UUID().uuidString, name: fc["name"] as? String ?? "",
                                                      argumentsJSON: HTTPStream.string(fc["args"] ?? [String: Any]()))))
                        continue
                    }
                    guard let t = p["text"] as? String, !t.isEmpty else {
                        if p["thoughtSignature"] != nil { st.lock.withLock { st.parts.append(p) } }
                        continue
                    }
                    if (p["thought"] as? Bool) == true {
                        out.append(.thinking(t))
                    } else {
                        st.lock.withLock { st.parts.append(p) }
                        out.append(.text(t))
                    }
                }
            }
            return out
        }, finish: {
            st.lock.withLock {
                guard st.parts.contains(where: { $0["functionCall"] != nil }) else { return [] }
                return [.assistantRaw(HTTPStream.string(st.parts))]
            }
        })
    }
}
