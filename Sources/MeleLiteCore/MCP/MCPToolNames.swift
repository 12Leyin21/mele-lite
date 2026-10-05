import Foundation

/// 外面的工具给模型时的名字：<slug>_<原名>。三家都只认 [a-zA-Z0-9_-]、最长 64。
public enum MCPToolNames {
    public static func slug(_ serverName: String, fallbackIndex: Int) -> String {
        var out = ""
        for ch in serverName.lowercased().unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { out.unicodeScalars.append(ch) }
            else if !out.isEmpty, !out.hasSuffix("_") { out += "_" }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "mcp\(fallbackIndex)" : String(out.prefix(20))
    }

    public static func exposed(_ slug: String, _ tool: String) -> String {
        let clean = String(String.UnicodeScalarView(tool.unicodeScalars.map { s in
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == "_" || s == "-" ? s : "_"
        }))
        return String("\(slug)_\(clean)".prefix(64))
    }

    /// 最长的 slug 先认，免得 mem 抢了 memory 的工具
    public static func split(_ exposed: String, slugs: [String]) -> (slug: String, tool: String)? {
        for s in slugs.sorted(by: { $0.count > $1.count }) where exposed.hasPrefix(s + "_") {
            return (s, String(exposed.dropFirst(s.count + 1)))
        }
        return nil
    }
}

/// Gemini 的 functionDeclarations 只认 OpenAPI 的一小块：剥掉它不认的字段，anyOf[x, null] 改成 nullable。
public enum GeminiSchema {
    static let drop: Set<String> = ["$schema", "$id", "$defs", "definitions", "additionalProperties", "title", "default", "examples", "const"]

    public static func clean(_ schema: [String: Any]) -> [String: Any] {
        var s = schema
        if let any = s["anyOf"] as? [[String: Any]] {
            let nonNull = any.filter { ($0["type"] as? String) != "null" }
            if nonNull.count == 1 {
                s.removeValue(forKey: "anyOf")
                for (k, v) in nonNull[0] { s[k] = v }
                if nonNull.count < any.count { s["nullable"] = true }
            }
        }
        for k in drop { s.removeValue(forKey: k) }
        if let props = s["properties"] as? [String: Any] {
            s["properties"] = props.mapValues { ($0 as? [String: Any]).map(clean) ?? $0 }
        }
        if let items = s["items"] as? [String: Any] { s["items"] = clean(items) }
        return s
    }
}
