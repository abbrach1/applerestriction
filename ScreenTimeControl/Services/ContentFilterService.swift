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
                let pc = NEFilterProviderConfiguration()
                pc.filterBrowsers = true
                pc.filterSockets  = true
                NEFilterManager.shared().providerConfiguration = pc
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
    /// Saving preferences causes the extension to restart and reload rules.
    func updateRules(_ config: ScreenTimeConfiguration) async {
        writeRules(config)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NEFilterManager.shared().loadFromPreferences { _ in
                guard NEFilterManager.shared().isEnabled else {
                    continuation.resume(); return
                }
                NEFilterManager.shared().saveToPreferences { _ in continuation.resume() }
            }
        }
    }

    // MARK: - Private

    private func writeRules(_ config: ScreenTimeConfiguration) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(config.blockedWebsites,                    forKey: "bsafe.filter.blockedDomains")
        defaults.set(config.allowedWebsites,                    forKey: "bsafe.filter.allowedDomains")
        defaults.set(config.websiteFilterMode == .whitelist,    forKey: "bsafe.filter.whitelist")
        defaults.set(config.isLocked,                           forKey: "bsafe.filter.locked")
        defaults.set(config.captiveBypassUntil,                 forKey: "bsafe.filter.captiveBypassUntil")
    }

    /// Opens the captive-portal bypass window by writing the epoch seconds
    /// the window should end at. NEFilter reads this on every flow so it
    /// picks up the change without needing a preferences save (which would
    /// restart the extension and cost seconds at the worst possible moment —
    /// right when the kid is trying to auth to the hotel WiFi).
    func openCaptiveBypass(until: TimeInterval) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(until, forKey: "bsafe.filter.captiveBypassUntil")
    }

    func closeCaptiveBypass() { openCaptiveBypass(until: 0) }
}
#endif
