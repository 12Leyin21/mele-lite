import Foundation

/// 设定页里「用哪家」那一栏：比三种接头细一层——DeepSeek、OpenRouter 也是 OpenAI 兼容，但让用户直接点得到（Tilia 10-04：模型咋没有 DeepSeek）。
public enum ProviderService: String, CaseIterable, Sendable {
    case anthropic, openai, deepseek, gemini, openrouter, custom

    public var title: String {
        switch self {
        case .anthropic: "Claude（Anthropic）"
        case .openai: "ChatGPT（OpenAI）"
        case .deepseek: "DeepSeek"
        case .gemini: "Gemini（Google）"
        case .openrouter: "OpenRouter"
        case .custom: "其他（OpenAI 兼容）"
        }
    }

    var kind: ProviderKind {
        switch self {
        case .anthropic: .anthropic
        case .gemini: .gemini
        default: .openai
        }
    }

    var baseURL: String? {
        switch self {
        case .deepseek: "https://api.deepseek.com"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .openai: "https://api.openai.com/v1"
        default: nil
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5"
        case .gemini: "gemini-3.5-flash-lite"
        case .deepseek: "deepseek-flash"
        default: ""
        }
    }

    public static func of(_ c: ProviderConfig) -> ProviderService {
        switch c.kind {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .openai:
            let host = c.baseURL.flatMap { URL(string: $0)?.host } ?? "api.openai.com"
            switch host {
            case "api.openai.com": return .openai
            case "api.deepseek.com": return .deepseek
            case "openrouter.ai": return .openrouter
            default: return .custom
            }
        }
    }

    /// 换到这一家：接头、地址、默认模型跟着换，「思考」开关留着
    public func config(keeping old: ProviderConfig) -> ProviderConfig {
        ProviderConfig(kind: kind, baseURL: baseURL, model: defaultModel, thinking: old.thinking)
    }
}
