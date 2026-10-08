import Testing
@testable import MeleLiteCore

@Suite struct HandbookTests {
    @Test func lifeOffDropsRightNowLine() {
        let off = Handbook.text(zh: true, online: true, life: false, memoryTools: nil)
        let on = Handbook.text(zh: true, online: true, life: true, memoryTools: nil)
        #expect(!off.contains("〔现在〕"))
        #expect(on.contains("〔现在〕"))
        #expect(off.contains("〔饮食〕"))
        #expect(!off.contains("记忆库"))          // 没接记忆库不给那一节
        #expect(off.contains("写纯文字"))
        #expect(!Handbook.text(zh: false, online: true, life: false, memoryTools: nil).contains("[Right now]"))
    }

    @Test func memorySectionFillsToolNames() {
        let t = Handbook.text(zh: true, online: false, life: false, memoryTools: ("mem_remember", "mem_search"))
        #expect(t.contains("当场记（mem_remember）"))
        #expect(t.contains("先 mem_search 再答"))
        #expect(!t.contains("{remember}"))
        #expect(!t.contains("写纯文字"))          // 线下不给说话那几条
    }

    @Test func relationshipPacks() {
        #expect(Relationship.pack("", zh: true).hasPrefix("我跟 TA 像很熟的老朋友"))           // 没选 = 朋友
        #expect(Relationship.pack("partner", zh: true).hasPrefix("TA 说我们是恋人"))
        #expect(Relationship.pack("青梅竹马", zh: true).contains("「青梅竹马」"))               // 自定义
        #expect(!Relationship.pack("buddy", zh: false).isEmpty)
    }
}
