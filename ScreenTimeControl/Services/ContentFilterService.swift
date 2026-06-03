#if !targetEnvironment(simulator)
import Foundation
import NetworkExtension

/// Manages the NEFilterDataProvider content filter extension.
///
/// Works alongside NextDNS — NextDNS handles parental control features
/// (SafeSearch, category blocking, etc.) while this handles domain
/// allow/block enforcement that cannot be bypassed by switching DNS.
@MainActor
class ContentFilterService {
    static let shared = ContentFilterService()

    private let appGroupID    = "group.com.abbrachfeld.bsafe"
    private let filterBundleID = "com.abbrachfeld.screentimecontrolabbrach.BSAFEContentFilter"

    private init() {}

    // MARK: - Public API

    func isEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            NEFilterManager.shared().loadFromPreferences { _ in
                continuation.resume(returning: NEFilterManager.shared().isEnabled)
            }
        }
    }

    /// Write rules to shared container and enable the filter.
    /// Returns an error description if saveToPreferences fails, nil on success.
    @discardableResult
    func enable(config: ScreenTimeConfiguration) async -> String? {
        writeRules(config)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            NEFilterManager.shared().loadFromPreferences { _ in
                NEFilterManager.shared().providerConfiguration = Self.makeProviderConfiguration()
                NEFilterManager.shared().isEnabled = true
                NEFilterManager.shared().localizedDescription = "B-SAFE Content Filter"
                NEFilterManager.shared().saveToPreferences { error in
                    if let error {
                        print("[B-SAFE] ContentFilter enable error: \(error)")
                        continuation.resume(returning: error.localizedDescription)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// Disable the filter (rules are preserved, just not active).
    func disable() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NEFilterManager.shared().loadFromPreferences { _ in
                NEFilterManager.shared().isEnabled = false
                NEFilterManager.shared().saveToPreferences { _ in continuation.resume() }
            }
        }
    }

    /// Push updated rules to the extension without disabling/re-enabling.
    /// Bumps the provider configuration so iOS notices a change and
    /// restarts the extension, which re-reads the rules in startFilter.
    func updateRules(_ config: ScreenTimeConfiguration) async {
        writeRules(config)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NEFilterManager.shared().loadFromPreferences { _ in
                guard NEFilterManager.shared().isEnabled else {
                    continuation.resume(); return
                }
                NEFilterManager.shared().providerConfiguration = Self.makeProviderConfiguration()
                NEFilterManager.shared().saveToPreferences { _ in continuation.resume() }
            }
        }
    }

    // MARK: - Private

    /// Builds a fresh provider configuration with a unique revision string,
    /// so each call yields a non-equal configuration. Without this iOS may
    /// short-circuit saveToPreferences when nothing else changed and the
    /// extension will not restart to pick up new rules.
    private static func makeProviderConfiguration() -> NEFilterProviderConfiguration {
        let pc = NEFilterProviderConfiguration()
        pc.filterBrowsers = true
        pc.filterSockets  = true
        pc.vendorConfiguration = ["rev": UUID().uuidString]
        return pc
    }

    private func writeRules(_ config: ScreenTimeConfiguration) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let blocked = Array(Set(config.blockedWebsites.compactMap(DomainNormalizer.normalize)))
        let allowed = Array(Set(config.allowedWebsites.compactMap(DomainNormalizer.normalize)))
        defaults.set(blocked,                                   forKey: "bsafe.filter.blockedDomains")
        defaults.set(allowed,                                   forKey: "bsafe.filter.allowedDomains")
        defaults.set(config.websiteFilterMode == .whitelist,    forKey: "bsafe.filter.whitelist")
        defaults.set(config.isLocked,                           forKey: "bsafe.filter.locked")
    }
}
#endif
