import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct ConsentBookTests {
    func fresh() -> ConsentBook {
        let d = UserDefaults(suiteName: "consent-\(UUID())")!
        return ConsentBook(defaults: d)
    }

    @Test func askOncePerProviderAndHost() {
        let book = fresh()
        let ds = ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let or = ProviderConfig(kind: .openai, baseURL: "https://openrouter.ai/api/v1", model: "x")
        #expect(book.needsAsk(ds))
        book.grant(ds)
        #expect(!book.needsAsk(ds))
        #expect(book.needsAsk(or))
        book.revokeAll()
        #expect(book.needsAsk(ds))
    }

    @Test func hostShownToUser() {
        #expect(ConsentBook.host(ProviderConfig(kind: .anthropic, model: "m")) == "api.anthropic.com")
        #expect(ConsentBook.host(ProviderConfig(kind: .gemini, model: "m")) == "generativelanguage.googleapis.com")
        #expect(ConsentBook.host(ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "m")) == "api.deepseek.com")
        #expect(ConsentBook.host(ProviderConfig(kind: .openai, model: "m")) == "api.openai.com")
    }
}
