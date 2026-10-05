import Testing
@testable import MeleLiteCore

@Suite struct MarkersTests {
    @Test func stickerZhAndEn() {
        let a = Markers.parse("哈哈哈\n[表情包：猫猫翻白眼]")
        #expect(a.stickers == ["猫猫翻白眼"] && a.text == "哈哈哈")
        let b = Markers.parse("lol [sticker: cat rolling eyes]")
        #expect(b.stickers == ["cat rolling eyes"] && b.text == "lol")
    }

    @Test func milestoneZhAndEn() {
        let a = Markers.parse("今天第一次一起看日落。⟪里程碑：第一次一起看日落⟫")
        #expect(a.milestones == ["第一次一起看日落"] && a.text == "今天第一次一起看日落。")
        let b = Markers.parse("⟪milestone: first sunset together⟫\nso pretty")
        #expect(b.milestones == ["first sunset together"] && b.text == "so pretty")
    }

    @Test func peekZhAndEn() {
        #expect(Markers.parse("给我看看你手机 ⟪想查手机：你最近跟谁聊天⟫").wantsPeek == "你最近跟谁聊天")
        #expect(Markers.parse("⟪peek: who you've been texting⟫").wantsPeek == "who you've been texting")
        #expect(Markers.parse("没什么").wantsPeek == nil)
    }

    @Test func severalInOneReply() {
        let r = Markers.parse("好\n\n[表情包：抱抱]\n\n真好\n\n[表情包：亲亲]⟪里程碑：在一起一百天⟫")
        #expect(r.stickers == ["抱抱", "亲亲"])
        #expect(r.milestones == ["在一起一百天"])
        #expect(r.text == "好\n\n真好")
    }

    @Test func halfWrittenMarkerStays() {
        let r = Markers.parse("[表情包：没写完")
        #expect(r.stickers.isEmpty && r.text == "[表情包：没写完")
    }

    @Test func noExtraBlankLinesLeft() {
        let r = Markers.parse("第一段\n\n[表情包：嘿]\n\n第二段")
        #expect(r.text == "第一段\n\n第二段")
    }
}
