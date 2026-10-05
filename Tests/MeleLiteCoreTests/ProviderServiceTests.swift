import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct ProviderServiceTests {
    @Test func recognisesEachService() {
        #expect(ProviderService.of(ProviderConfig(kind: .anthropic, model: "m")) == .anthropic)
        #expect(ProviderService.of(ProviderConfig(kind: .gemini, model: "m")) == .gemini)
        #expect(ProviderService.of(ProviderConfig(kind: .openai, baseURL: "https://api.deepseek.com", model: "m")) == .deepseek)
        #expect(ProviderService.of(ProviderConfig(kind: .openai, baseURL: "https://openrouter.ai/api/v1", model: "m")) == .openrouter)
        #expect(ProviderService.of(ProviderConfig(kind: .openai, model: "m")) == .openai)
        #expect(ProviderService.of(ProviderConfig(kind: .openai, baseURL: "https://api.openai.com/v1", model: "m")) == .openai)
        #expect(ProviderService.of(ProviderConfig(kind: .openai, baseURL: "https://my.host/v1", model: "m")) == .custom)
    }

    @Test func switchingSetsKindURLAndDefaultModel() {
        let c = ProviderService.deepseek.config(keeping: ProviderConfig(kind: .anthropic, model: "claude-sonnet-5", thinking: true))
        #expect(c.kind == .openai)
        #expect(c.baseURL == "https://api.deepseek.com")
        #expect(c.model == "deepseek-flash")
        #expect(c.thinking)
        let custom = ProviderService.custom.config(keeping: c)
        #expect(custom.kind == .openai && custom.baseURL == nil && custom.model == "")
    }
}
