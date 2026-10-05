import Foundation
import Testing
@testable import MeleLiteCore

/// 测试里现做的卡（不放任何人的真卡）。PNG = 签名 + 一个 tEXt 块 + IEND（解析不验 CRC）。
func makePNG(_ texts: [(String, String)]) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    func chunk(_ kind: String, _ body: Data) {
        var n = UInt32(body.count).bigEndian
        d.append(Data(bytes: &n, count: 4)); d.append(kind.data(using: .ascii)!); d.append(body); d.append(Data([0, 0, 0, 0]))
    }
    for (k, v) in texts { chunk("tEXt", k.data(using: .isoLatin1)! + Data([0]) + v.data(using: .isoLatin1)!) }
    chunk("IEND", Data())
    return d
}

func b64(_ obj: [String: Any]) -> String { try! JSONSerialization.data(withJSONObject: obj).base64EncodedString() }

nonisolated(unsafe) let v2: [String: Any] = ["spec": "chara_card_v2", "data": [
    "name": "林晚", "description": "{{char}} 是一个画画的人，喜欢 {{user}}。", "personality": "安静",
    "scenario": "雨天的画室", "first_mes": "你来了。", "alternate_greetings": ["又是你。"],
    "mes_example": "<START>\n{{char}}: 嗯。", "system_prompt": "{{original}} 说话慢一点",
    "character_book": ["entries": [
        ["keys": ["画室", "a"], "content": "画室在三楼", "comment": "画室"],
        ["keys": ["x"], "content": "只有短关键词"],
        ["keys": [], "content": "常驻设定", "constant": true],
    ]]]]

@Suite struct CardParserTests {
    @Test func pngV2() throws {
        let c = try CardParser.parse(makePNG([("chara", b64(v2))]), userName: "小满", lang: .zh)
        #expect(c.name == "林晚")
        #expect(c.greetings == ["你来了。", "又是你。"])
        #expect(c.persona.contains("林晚 是一个画画的人，喜欢 小满。"))
        #expect(c.persona.contains("## 场景\n雨天的画室"))
        #expect(c.persona.contains("## 作者对这个角色的说明\n说话慢一点"))
        #expect(!c.persona.contains("<START>"))
        #expect(c.avatarPNG != nil)
        #expect(c.lore.map(\.title) == ["画室", "林晚"])
        #expect(c.lore.first?.keys == ["画室"])
        #expect(c.lore.last?.constant == true)
        #expect(c.skippedLore == 1)
    }

    @Test func ccv3Preferred() throws {
        var v3 = v2; v3["spec"] = "chara_card_v3"
        var data = v3["data"] as! [String: Any]; data["name"] = "林晚V3"; v3["data"] = data
        let c = try CardParser.parse(makePNG([("chara", b64(v2)), ("ccv3", b64(v3))]), userName: "", lang: .zh)
        #expect(c.name == "林晚V3")
    }

    @Test func jsonAndV1() throws {
        let json = try JSONSerialization.data(withJSONObject: v2)
        #expect(try CardParser.parse(json, userName: "", lang: .en).name == "林晚")
        let v1 = try JSONSerialization.data(withJSONObject: ["name": "Old", "description": "hi {{user}}", "first_mes": "yo"])
        let c = try CardParser.parse(v1, userName: "", lang: .en)
        #expect(c.name == "Old" && c.persona.contains("hi you") && c.avatarPNG == nil)
    }

    @Test func notACard() {
        #expect(throws: CardError.self) { try CardParser.parse(makePNG([("Comment", "hello")]), userName: "", lang: .zh) }
        #expect(throws: CardError.self) { try CardParser.parse(Data("not json".utf8), userName: "", lang: .zh) }
    }

    @Test func tooBig() {
        #expect(throws: CardError.self) { try CardParser.parse(Data(count: 10 * 1024 * 1024 + 1), userName: "", lang: .zh) }
        let long = try! JSONSerialization.data(withJSONObject: ["name": "L", "description": String(repeating: "字", count: 30_001)])
        #expect(throws: CardError.self) { try CardParser.parse(long, userName: "", lang: .zh) }
    }
}
