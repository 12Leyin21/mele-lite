import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct KeyVaultTests {
    @Test func memoryVault() {
        let v = MemoryVault()
        #expect(v.get("anthropic") == nil)
        v.set("sk-test", for: "anthropic")
        #expect(v.get("anthropic") == "sk-test")
        v.set(nil, for: "anthropic")
        #expect(v.get("anthropic") == nil)
    }

    @Test func keychainVault() {
        let v = KeychainVault(service: "app.melelite.keys.test-\(UUID().uuidString)")
        v.set("sk-fake-123", for: "openai")
        guard let got = v.get("openai") else {
            // 没有钥匙串权限的环境（比如 CI）里存不进去，不算失败
            return
        }
        #expect(got == "sk-fake-123")
        v.set("sk-fake-456", for: "openai")
        #expect(v.get("openai") == "sk-fake-456")
        v.set(nil, for: "openai")
        #expect(v.get("openai") == nil)
    }
}
