import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct MCPLogicTests {
    @Test func slugs() {
        #expect(MCPToolNames.slug("Memory", fallbackIndex: 1) == "memory")
        #expect(MCPToolNames.slug("我的记忆库", fallbackIndex: 2) == "mcp2")
        #expect(MCPToolNames.slug("My Notes!", fallbackIndex: 1) == "my_notes")
        let long = MCPToolNames.exposed("memory", String(repeating: "x", count: 80))
        #expect(long.count == 64)
        #expect(MCPToolNames.exposed("memory", "date.add") == "memory_date_add")
        let hit = MCPToolNames.split("memory_date_add", slugs: ["mem", "memory"])
        #expect(hit?.slug == "memory" && hit?.tool == "date_add")
        #expect(MCPToolNames.split("wallet_add", slugs: ["memory"]) == nil)
    }

    @Test func geminiSchemaStripsUnsupportedKeys() {
        let s: [String: Any] = ["$schema": "x", "type": "object", "additionalProperties": false, "title": "T",
                                "properties": ["a": ["type": "string", "title": "A", "default": "1"],
                                               "b": ["anyOf": [["type": "string"], ["type": "null"]]]]]
        let c = GeminiSchema.clean(s)
        #expect(c["$schema"] == nil && c["additionalProperties"] == nil && c["title"] == nil)
        let a = (c["properties"] as! [String: Any])["a"] as! [String: Any]
        #expect(a["title"] == nil && a["default"] == nil && a["type"] as? String == "string")
        let b = (c["properties"] as! [String: Any])["b"] as! [String: Any]
        #expect(b["type"] as? String == "string" && b["nullable"] as? Bool == true)
    }

    private func p(_ id: Int?, _ name: String, user: Bool, facts: String = "", aliases: [String] = []) -> MovePerson {
        MovePerson(id: id, name: name, aliases: aliases, relation: "", facts: facts, impression: "", byUser: user)
    }

    @Test func peopleMoveRules() {
        let from = [p(1, "小满妈妈", user: true, facts: "手机写的"),               // 对面是 TA 写的 → 盖过去
                    p(2, "阿青", user: false, facts: "TA 记的", aliases: ["青青"]), // 对面是用户写的 → 只补别名
                    p(3, "老周", user: true, facts: "手机写的"),                    // 两边都是用户写的 → 看 sourceWinsTies
                    p(4, "新朋友", user: false)]                                    // 对面没有 → 新建
        let into = [p(11, "小满妈妈", user: false, facts: "TA 记的"),
                    p(12, "阿青", user: true, facts: "用户写的"),
                    p(13, "老周", user: true, facts: "远端写的")]
        let out = MemoryMove.people(from: from, into: into, sourceWinsTies: true)
        #expect(out == [.overwrite(targetID: 11, from[0]),
                        .addAliases(targetID: 12, ["青青"]),
                        .overwrite(targetID: 13, from[2]),
                        .create(from[3])])
        let back = MemoryMove.people(from: [from[2]], into: [into[2]], sourceWinsTies: false)
        #expect(back == [])
    }

    @Test func datesDedupe() {
        let a = MoveDate(day: "2026-11-02", title: "雅思", time: "", note: "")
        let b = MoveDate(day: "2026-11-02", title: " 雅思 ", time: "09:00", note: "")
        let c = MoveDate(day: "2026-12-21", title: "生日", time: "", note: "")
        #expect(MemoryMove.dates(from: [b, c], into: [a]) == [c])
    }
}
