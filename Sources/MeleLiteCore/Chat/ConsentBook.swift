import Foundation

/// 苹果 5.1.2(i)：把消息发给第三方 AI 之前要说清楚、要用户点同意。按「哪家 + 哪个地址」记，同意过就不再问。
public final class ConsentBook: @unchecked Sendable {
    let defaults: UserDefaults
    let key = "aiConsent.granted"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var granted: Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }

    public func needsAsk(_ c: ProviderConfig) -> Bool { !granted.contains(KeyName.of(c)) }

    public func grant(_ c: ProviderConfig) {
        defaults.set(Array(granted.union([KeyName.of(c)])).sorted(), forKey: key)
    }

    public func revokeAll() { defaults.removeObject(forKey: key) }

    public static func host(_ c: ProviderConfig) -> String {
        switch c.kind {
        case .anthropic: return "api.anthropic.com"
        case .gemini: return "generativelanguage.googleapis.com"
        case .openai: return c.baseURL.flatMap { URL(string: $0)?.host } ?? "api.openai.com"
        }
    }
}
