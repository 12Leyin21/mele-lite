#if LITE
import SwiftUI
import MeleLiteCore

/// 苹果 5.1.2(i)：第一次把消息发给某家模型之前，说清楚发给谁、请用户点同意（按「哪家 + 哪个地址」记）
enum LiteConsent {
    static let book = ConsentBook()

    struct Ask: Identifiable {
        let provider: ProviderConfig
        let text: String
        var id: String { KeyName.of(provider) }
        var host: String { ConsentBook.host(provider) }
        var company: String {
            switch provider.kind {
            case .anthropic: "Anthropic"
            case .gemini: "Google"
            case .openai: host
            }
        }
    }

    /// 这个联系人这一句发出去之前要不要先问；不用问（或者还没配 key，管家会自己报错）返回 nil
    static func ask(companion: UUID, text: String) -> Ask? {
        guard let c = LocalHost.shared.store.companion(companion.uuidString.lowercased()),
              let (provider, _) = LocalHost.shared.route(for: c), book.needsAsk(provider) else { return nil }
        return Ask(provider: provider, text: text)
    }
}

struct LiteConsentSheet: View {
    @EnvironmentObject private var theme: AppTheme
    let ask: LiteConsent.Ask
    var onAgree: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(theme.accent)
            Text("你的消息会发到哪里")
                .font(Typo.sans(Typo.Size.title, .semibold))
                .foregroundStyle(theme.ink)
            Text("你的消息（包括你发的照片、TA 的人设和你们的聊天记录）会直接从这台手机发到 **\(ask.host)**（\(ask.company)），由它生成 TA 的回复。\n\nMele Lite 没有服务器，不经手、也不保存你的消息。这家服务怎么处理数据，请看它们的隐私条款。")
                .font(Typo.sans(Typo.Size.body))
                .foregroundStyle(theme.inkDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onAgree) {
                Text("同意并发送")
                    .font(Typo.sans(Typo.Size.body, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            Button("先不发", action: onCancel)
                .font(Typo.sans(Typo.Size.body))
                .foregroundStyle(theme.inkDim)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(AppBackground())
        .environment(\.colorScheme, .light)
    }
}
#endif
