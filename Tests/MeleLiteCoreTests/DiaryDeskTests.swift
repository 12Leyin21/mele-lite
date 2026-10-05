import Testing
@testable import MeleLiteCore

/// TA 写日记（10-05，Lite 本机）。测试用小满 / Mia。
@Suite struct DiaryDeskTests {
    @Test func promptCarriesMaterialsAndLimit() {
        let p = DiaryDesk.prompt(now: "2026-10-06 08:00", day: "2026-10-05", materials: "小满：今天考完了", limit: 600, lang: .zh)
        #expect(p.contains("小满：今天考完了") && p.contains("别超过 600 字") && p.contains("〔正文〕") && !p.contains("锁着"))
    }

    @Test func parseSplitsBodyAndMargins() {
        let got = DiaryDesk.parse("好的，下面是日记：\n〔正文〕\n今天她考完了，我替她松了口气。\n\n晚上她说想去海边。\n〔页边 #3〕考完了，去吹吹风吧。\n多的一行\n〔页边 #x〕坏的")
        #expect(got.body == "今天她考完了，我替她松了口气。\n\n晚上她说想去海边。")
        #expect(got.margins == [3: "考完了，去吹吹风吧。"])
    }

    @Test func noTagsMeansWholeTextIsTheBody() {
        #expect(DiaryDesk.parse("  就这一句。 ").body == "就这一句。")
        #expect(DiaryDesk.parse("〔Entry〕\nA quiet day.").body == "A quiet day.")
    }
}
