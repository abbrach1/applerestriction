import NetworkExtension
import os

/// NEFilterDataProvider extension for B-SAFE.
///
/// Intercepts every network flow on the device and returns allow/drop
/// based on the current configuration written to the shared App Group
/// container by the main app.
///
/// Rules are loaded once at startFilter and reloaded whenever the main
/// app calls NEFilterManager.saveToPreferences (which restarts this extension).
class ContentFilterProvider: NEFilterDataProvider {

    private let appGroupID = "group.com.abbrachfeld.bsafe"
    private let log = OSLog(subsystem: "com.abbrachfeld.screentimecontrolabbrach.BSAFEContentFilter",
                            category: "filter")

    // Cached rules — loaded in startFilter
    private var blockedDomains:  Set<String> = []
    private var allowedDomains:  Set<String> = []
    private var isWhitelistMode: Bool = false
    private var isLocked:        Bool = false

    // Always pass through — iOS system services and the app's own backend.
    // Without these the device becomes unusable (no App Store, no updates, app can't sync).
    private let alwaysAllowed: [String] = [
        "apple.com", "icloud.com", "apple-cloudkit.com", "mzstatic.com",
        "cdn-apple.com", "apple-dns.net",
        "firebase.com", "firebaseio.com", "firebaseapp.com",
        "googleapis.com", "gstatic.com", "google-analytics.com",
        "nextdns.io",
        "abbrachfeld.com"
    ]

    // MARK: - Lifecycle

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        loadRules()
        os_log("ContentFilter started — whitelist=%{public}d locked=%{public}d blocked=%d allowed=%d",
               log: log, type: .info,
               isWhitelistMode, isLocked,
               blockedDomains.count, allowedDomains.count)
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: - Flow handling

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let host = hostname(from: flow)
        guard !host.isEmpty else { return .allow() }

        // Never block essential system / app services
        if isEssential(host) {
            logDecision(host: host, allowed: true, reason: "essential")
            return .allow()
        }

        // Full lock — block everything else
        if isLocked {
            logDecision(host: host, allowed: false, reason: "locked")
            return .drop()
        }

        if isWhitelistMode {
            // Allow only explicitly permitted domains
            let allowed = allowedDomains.contains { matches(host: host, rule: $0) }
            logDecision(host: host, allowed: allowed, reason: "whitelist")
            return allowed ? .allow() : .drop()
        } else {
            // Block explicitly listed domains
            let blocked = blockedDomains.contains { matches(host: host, rule: $0) }
            logDecision(host: host, allowed: !blocked, reason: "blacklist")
            return blocked ? .drop() : .allow()
        }
    }

    private func logDecision(host: String, allowed: Bool, reason: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var logs = defaults.array(forKey: "bsafe.filter.logs") as? [[String: Any]] ?? []
        let entry: [String: Any] = [
            "host": host,
            "allowed": allowed,
            "reason": reason,
            "timestamp": Date().timeIntervalSince1970
        ]
        logs.append(entry)
        // Keep last 200 entries
        if logs.count > 200 { logs = Array(logs.suffix(200)) }
        defaults.set(logs, forKey: "bsafe.filter.logs")
    }

    // MARK: - Helpers

    private func hostname(from flow: NEFilterFlow) -> String {
        if let socketFlow = flow as? NEFilterSocketFlow {
            return socketFlow.remoteHostname ?? ""
        }
        if let browserFlow = flow as? NEFilterBrowserFlow {
            return browserFlow.url?.host ?? ""
        }
        return ""
    }

    /// Returns true if `host` matches `rule` exactly or as a subdomain.
    /// Tolerant of protocol prefixes, paths, ports, and `www.` so admin entries
    /// like "https://www.youtube.com/" still match "m.youtube.com".
    private func matches(host: String, rule: String) -> Bool {
        guard let r = normalizeDomain(rule), let h = normalizeDomain(host) else { return false }
        return h == r || h.hasSuffix(".\(r)")
    }

    /// Strip protocol, path, query, port, leading `www.`, and trailing dot.
    private func normalizeDomain(_ raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let r = s.firstIndex(of: "/") { s = String(s[..<r]) }
        if let r = s.firstIndex(of: "?") { s = String(s[..<r]) }
        if let r = s.firstIndex(of: "#") { s = String(s[..<r]) }
        if let r = s.firstIndex(of: ":") { s = String(s[..<r]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s.isEmpty ? nil : s
    }

    private func isEssential(_ host: String) -> Bool {
        alwaysAllowed.contains { matches(host: host, rule: $0) }
    }

    // MARK: - Rule loading

    private func loadRules() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        blockedDomains  = Set(defaults.stringArray(forKey: "bsafe.filter.blockedDomains") ?? [])
        allowedDomains  = Set(defaults.stringArray(forKey: "bsafe.filter.allowedDomains") ?? [])
        isWhitelistMode = defaults.bool(forKey: "bsafe.filter.whitelist")
        isLocked        = defaults.bool(forKey: "bsafe.filter.locked")
    }
}
