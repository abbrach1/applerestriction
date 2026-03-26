import ManagedSettings
import ManagedSettingsUI
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground,
            icon: UIImage(systemName: "hourglass.circle.fill"),
            title: ShieldConfiguration.Label(text: "App Restricted", color: .label),
            subtitle: ShieldConfiguration.Label(
                text: application.localizedDisplayName
                    .map { "\($0) is currently restricted." }
                    ?? "This app is currently restricted.",
                color: .secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue,
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Request More Time",
                color: .systemBlue
            )
        )
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground,
            icon: UIImage(systemName: "hourglass.circle.fill"),
            title: ShieldConfiguration.Label(text: "Category Restricted", color: .label),
            subtitle: ShieldConfiguration.Label(
                text: "Apps in this category are currently restricted.",
                color: .secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground,
            icon: UIImage(systemName: "globe.badge.chevron.backward"),
            title: ShieldConfiguration.Label(text: "Website Restricted", color: .label),
            subtitle: ShieldConfiguration.Label(
                text: webDomain.domain.map { "\($0) is restricted." }
                    ?? "This website is currently restricted.",
                color: .secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground,
            icon: UIImage(systemName: "globe.badge.chevron.backward"),
            title: ShieldConfiguration.Label(text: "Category Restricted", color: .label),
            subtitle: ShieldConfiguration.Label(
                text: "Websites in this category are currently restricted.",
                color: .secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }
}
