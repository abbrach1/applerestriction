#if !targetEnvironment(simulator)
import Foundation
import SafariServices
@preconcurrency import NetworkExtension

/// Manages the Safari Content Blocker and DNS-over-HTTPS settings for B-SAFE.
///
/// Content Blocker:
///   - Generates a WebKit content-blocker rules JSON array based on the
///     current ScreenTimeConfiguration and writes it to the shared App Group
///     container (group.com.abbrachfeld.bsafe/blockerRules.json).
///   - Calls SFContentBlockerManager to reload the extension so Safari picks
///     up the new rules immediately.
///
/// DNS:
///   - Uses NEDNSSettingsManager to install/remove a DNS-over-HTTPS profile
///     pointing at the CleanBrowsing Family Filter.  This blocks adult &
///     malware domains system-wide across ALL apps, not just Safari.
///   - No special Apple approval is needed for NEDNSSettingsManager
///     (unlike NEFilterDataProvider / NEContentFilterConfiguration).
@MainActor
class ContentBlockerService {
    static let shared = ContentBlockerService()

    private let appGroupID   = "group.com.abbrachfeld.bsafe"
    private let blockerBundleID = "com.abbrachfeld.screentimecontrolabbrach.BSAFEContentBlocker"
    private let dnsManagerKey = "bsafe.dnsProfile"

    private init() {}

    // MARK: - Content Blocker

    /// Build rules JSON from config and reload the Safari extension.
    func applyRules(for config: ScreenTimeConfiguration) {
        let rules = buildRules(for: config)
        writeRules(rules)
        reloadExtension()
    }

    /// Remove all content-blocker rules (allow everything in Safari).
    func clearRules() {
        writeRules([])
        reloadExtension()
    }

    // MARK: - DNS

    /// Returns whether the DNS profile is currently installed and enabled.
    /// Uses NextDNS test API if the profile was installed as a .mobileconfig,
    /// otherwise checks NEDNSSettingsManager directly.
    func isDNSEnabled() async -> Bool {
        if UserDefaults.standard.bool(forKey: "bsafe.dns.usingMobileConfig") {
            let profileID = UserDefaults.standard.string(forKey: "bsafe.dns.profileID") ?? ""
            return await MobileConfigService.shared.isDNSActive(profileID: profileID)
        }
        return await withCheckedContinuation { continuation in
            NEDNSSettingsManager.shared().loadFromPreferences { _ in
                continuation.resume(returning: NEDNSSettingsManager.shared().isEnabled)
            }
        }
    }

    /// Install a NextDNS DoH profile.
    ///
    /// Always installs as a .mobileconfig via Safari so the profile carries
    /// PayloadRemovalDisallowed=true (a no-op on consumer devices, an absolute
    /// block on supervised devices) and — when a removal password is set —
    /// RemovalPassword, which iOS itself enforces at removal time.
    ///
    /// On a consumer iPhone the only ways past the password are: enter it in
    /// Settings, or erase the entire device. There is no third path Apple
    /// permits a third-party app to expose.
    @discardableResult
    func enableForcedDNS(profileID: String, removalPassword: String = "") async -> String? {
        UserDefaults.standard.set(profileID, forKey: "bsafe.dns.profileID")
        UserDefaults.standard.set(true, forKey: "bsafe.dns.usingMobileConfig")
        await MobileConfigService.shared.install(
            profileID: profileID,
            removalPassword: removalPassword)
        return removalPassword.isEmpty
            ? "DNS profile installed without a removal password — child can remove it from Settings without authentication."
            : nil
    }

    /// Remove the B-SAFE DNS profile (restores device default DNS).
    ///
    /// Note: a configuration profile installed via .mobileconfig CANNOT be
    /// removed from app code on a consumer device — iOS requires user action
    /// in Settings (and the removal password). This call only:
    ///   1. Clears the app-side "DNS is forced" flag.
    ///   2. Best-effort removes any NEDNSSettingsManager profile from older
    ///      installs that predated the mobileconfig path.
    /// To fully turn it off, the admin must communicate the removal password
    /// so the child can delete the profile in Settings.
    func disableForcedDNS() async {
        UserDefaults.standard.set(false, forKey: "bsafe.dns.usingMobileConfig")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NEDNSSettingsManager.shared().loadFromPreferences { _ in
                NEDNSSettingsManager.shared().removeFromPreferences { error in
                    if let error { print("[B-SAFE] DNS remove error: \(error)") }
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Rule Builder

    private struct Rule: Codable {
        struct Action: Codable {
            let type: String
        }
        struct Trigger: Codable {
            let urlFilter: String
            let ifDomain: [String]?
            let unlessDomain: [String]?

            enum CodingKeys: String, CodingKey {
                case urlFilter    = "url-filter"
                case ifDomain     = "if-domain"
                case unlessDomain = "unless-domain"
            }
        }
        let action: Action
        let trigger: Trigger
    }

    private func buildRules(for config: ScreenTimeConfiguration) -> [Rule] {
        // If the device is locked or downtime is active — block everything
        if config.isLocked {
            return [blockAll()]
        }

        switch config.websiteFilterMode {
        case .blacklist:
            let domains = config.blockedWebsites.compactMap(DomainNormalizer.normalize)
            guard !domains.isEmpty else { return [] }
            // One block rule per domain, matched via url-filter so any request
            // to the domain or a subdomain is blocked (if-domain only filters by
            // the *page* domain, not the request URL, so it can't block navigation
            // to the domain itself — that was the prior bug).
            return Array(Set(domains)).map { blockDomain($0) }

        case .whitelist:
            let allowed = config.allowedWebsites.compactMap(DomainNormalizer.normalize)
            guard !allowed.isEmpty else {
                // No allowed list yet — block everything
                return [blockAll()]
            }
            // Block all http(s), then un-block each allowed domain (+ subdomains).
            var rules: [Rule] = [blockAll()]
            rules.append(contentsOf: Array(Set(allowed)).map { allowDomain($0) })
            return rules
        }
    }

    private func blockAll() -> Rule {
        Rule(
            action: Rule.Action(type: "block"),
            trigger: Rule.Trigger(urlFilter: "^https?://", ifDomain: nil, unlessDomain: nil)
        )
    }

    private func blockDomain(_ domain: String) -> Rule {
        Rule(
            action: Rule.Action(type: "block"),
            trigger: Rule.Trigger(
                urlFilter: Self.urlFilterForDomain(domain),
                ifDomain: nil,
                unlessDomain: nil
            )
        )
    }

    private func allowDomain(_ domain: String) -> Rule {
        Rule(
            action: Rule.Action(type: "ignore-previous-rules"),
            trigger: Rule.Trigger(
                urlFilter: Self.urlFilterForDomain(domain),
                ifDomain: nil,
                unlessDomain: nil
            )
        )
    }

    /// Builds a WebKit-content-blocker url-filter regex that matches the
    /// canonical domain and any subdomain. Example: "youtube.com" →
    /// "^https?://([^/]+\\.)?youtube\\.com([/?#:]|$)"
    private static func urlFilterForDomain(_ domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]+\\.)?\(escaped)([/?#:]|$)"
    }

    // MARK: - File I/O

    private func writeRules(_ rules: [Rule]) {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            print("[B-SAFE] App Group container not found — check entitlements")
            return
        }
        let fileURL = containerURL.appendingPathComponent("blockerRules.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(rules) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func reloadExtension() {
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: blockerBundleID) { error in
            if let error {
                print("[B-SAFE] Content blocker reload error: \(error)")
            }
        }
    }
}

#endif
