import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct MonologueTests {
    @Test func splitsTaggedMonologue() {
        let (mono, body) = Monologue.split("[独白]她今天好像累了，先别闹她。[/独白]\n\n累了就先躺会儿。")
        #expect(mono == "她今天好像累了，先别闹她。")
        #expect(body == "累了就先躺会儿。")
    }

    @Test func toleratesWonkyClosingTags() {
        for close in ["[独白 完]", "[独白结束]", "[/monologue]", "[end monologue]", "[独白/]"] {
            let (mono, body) = Monologue.split("[独白]想她。\(close)在呢。")
            #expect(mono == "想她。", "\(close)")
            #expect(body == "在呢。", "\(close)")
        }
    }

    @Test func noTagsMeansAllBody() {
        let (mono, body) = Monologue.split("  就这样。 ")
        #expect(mono.isEmpty)
        #expect(body == "就这样。")
    }

    @Test func unclosedSplitsAtFirstParagraphTalkingToYou() {
        let text = "[独白]她说「你别管我」，可她其实想被管。\n\n先接住她。\n\n你吃饭了没？\n\n我去热牛奶。"
        let (mono, body) = Monologue.split(text)
        #expect(mono == "她说「你别管我」，可她其实想被管。\n\n先接住她。")
        #expect(body == "你吃饭了没？\n\n我去热牛奶。")
    }

    @Test func rulesMentionToolsFirstAndStyle() {
        let r = Monologue.rules(zh: true, pronoun: "她", style: "短一点，像自言自语")
        #expect(r.contains("[独白]") && r.contains("[/独白]"))
        #expect(r.contains("先调工具"))
        #expect(r.contains("短一点，像自言自语"))
        #expect(!Monologue.rules(zh: false, pronoun: "they", style: "").isEmpty)
    }
}

@Suite struct MonologueTwiceTests {
    @Test func duplicatedMonologueDoesNotLeak() {
        let raw = "[独白]\n她走了，去忙。\n[/独白]\n\n[独白]\n她走了，去忙。\n[/独白]\n\n去忙吧。\n\n我在。"
        let (mono, body) = Monologue.split(raw)
        #expect(mono == "她走了，去忙。")
        #expect(body == "去忙吧。\n\n我在。")
    }

    @Test func twoDifferentMonologuesBothKept() {
        let (mono, body) = Monologue.split("[独白]甲[/独白]\n\n[独白]乙[/独白]\n\n好。")
        #expect(mono == "甲\n\n乙")
        #expect(body == "好。")
    }
}
