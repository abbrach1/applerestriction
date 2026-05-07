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
    /// If a removal password is set, installs as a .mobileconfig via Safari so
    /// the child must enter the password to remove it.
    /// Otherwise uses NEDNSSettingsManager (silent, no removal password).
    func enableForcedDNS(profileID: String, removalPassword: String = "") async {
        UserDefaults.standard.set(profileID, forKey: "bsafe.dns.profileID")
        if !removalPassword.isEmpty {
            await MobileConfigService.shared.install(
                profileID: profileID,
                removalPassword: removalPassword)
        } else {
            let urlString = profileID.isEmpty
                ? "https://dns.nextdns.io"
                : "https://dns.nextdns.io/\(profileID)"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                NEDNSSettingsManager.shared().loadFromPreferences { _ in
                    let doh = NEDNSOverHTTPSSettings(servers: ["45.90.28.0", "45.90.30.0"])
                    doh.serverURL = URL(string: urlString)
                    NEDNSSettingsManager.shared().dnsSettings = doh
                    NEDNSSettingsManager.shared().localizedDescription = "B-SAFE DNS Filter"
                    NEDNSSettingsManager.shared().saveToPreferences { error in
                        if let error { print("[B-SAFE] DNS save error: \(error)") }
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Remove the B-SAFE DNS profile (restores device default DNS).
    func disableForcedDNS() async {
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
            let domains = config.blockedWebsites.compactMap(DomainMatcher.normalize)
            guard !domains.isEmpty else { return [] }
            // Safari content-blocker if-domain syntax: a leading "*" matches the
            // domain and all of its subdomains. We normalize entries to bare hosts
            // (no protocol, no www., no path) so "*foo.com" matches "foo.com" and
            // "www.foo.com" and "m.foo.com" etc.
            return domains.map { domain in
                Rule(
                    action: Rule.Action(type: "block"),
                    trigger: Rule.Trigger(
                        urlFilter: ".*",
                        ifDomain: ["*\(domain)"],
                        unlessDomain: nil
                    )
                )
            }

        case .whitelist:
            let allowed = config.allowedWebsites.compactMap(DomainMatcher.normalize)
            guard !allowed.isEmpty else {
                // No allowed list yet — block everything
                return [blockAll()]
            }
            let prefixed = allowed.map { "*\($0)" }
            return [
                blockAll(),
                Rule(
                    action: Rule.Action(type: "ignore-previous-rules"),
                    trigger: Rule.Trigger(
                        urlFilter: ".*",
                        ifDomain: prefixed,
                        unlessDomain: nil
                    )
                )
            ]
        }
    }

    private func blockAll() -> Rule {
        Rule(
            action: Rule.Action(type: "block"),
            trigger: Rule.Trigger(urlFilter: ".*", ifDomain: nil, unlessDomain: nil)
        )
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
