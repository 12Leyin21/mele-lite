import ManagedSettings
import ManagedSettingsUI
import UIKit

/// 挡板上写什么：它最近弹过的那句（没有就第一句），「回去」和「我就看一下」。
final class FocusShieldExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration { make() }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration { make() }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { make() }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration { make() }

    private func make() -> ShieldConfiguration {
        let st = FocusSession.load()
        let line = st?.lastLine ?? st?.lines.first ?? "说好的专注呢？"
        let who = st?.companionName ?? "Mele"
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            title: ShieldConfiguration.Label(text: "先回去吧", color: .label),
            subtitle: ShieldConfiguration.Label(text: "\(who)：\(line)", color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "回去", color: .white),
            primaryButtonBackgroundColor: UIColor(red: 0.85, green: 0.45, blue: 0.55, alpha: 1),
            secondaryButtonLabel: ShieldConfiguration.Label(text: "我就看一下", color: .secondaryLabel))
    }
}
