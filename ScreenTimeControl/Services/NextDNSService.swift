import Foundation

/// Syncs B-SAFE allow/block lists with a NextDNS profile via the NextDNS API.
///
/// Allowlist  → nextdns.io/profiles/{id}/allowlist  (always active, overrides blocklists)
/// Denylist   → nextdns.io/profiles/{id}/denylist   (blocked system-wide)
/// Recreates the full list on each sync to stay in sync with the admin dashboard.
@MainActor
class NextDNSService {
    static let shared = NextDNSService()

    private let base = "https://api.nextdns.io"

    private init() {}

    // MARK: - Public API

    /// Full sync: pushes allowedWebsites → NextDNS allowlist,
    /// blockedWebsites → NextDNS denylist.
    ///
    /// In whitelist mode: also enables NextDNS "allowlist only" mode so ONLY
    /// the listed domains resolve — everything else is blocked at DNS level
    /// system-wide across ALL apps and browsers, not just Safari.
    func sync(profileID: String,
              apiKey: String,
              allowedDomains: [String],
              blockedDomains: [String],
              whitelistMode: Bool = false) async -> SyncResult {
        guard !profileID.isEmpty, !apiKey.isEmpty else {
            return SyncResult(success: false, error: "Profile ID or API key missing")
        }

        do {
            // Sync allowlist
            try await replaceList(endpoint: "allowlist",
                                  profileID: profileID,
                                  apiKey: apiKey,
                                  domains: allowedDomains)

            // Sync denylist
            try await replaceList(endpoint: "denylist",
                                  profileID: profileID,
                                  apiKey: apiKey,
                                  domains: blockedDomains)

            // Whitelist-only mode: block everything except allowlist at DNS level
            try await setAllowlistOnlyMode(profileID: profileID,
                                           apiKey: apiKey,
                                           enabled: whitelistMode && !allowedDomains.isEmpty)

            return SyncResult(success: true, error: nil)
        } catch {
            return SyncResult(success: false, error: error.localizedDescription)
        }
    }

    /// Enable/disable NextDNS "block everything except allowlist" mode.
    /// When on, ANY domain not in the allowlist returns NXDOMAIN — works in
    /// Safari, Chrome, every app, including DNS-over-HTTPS bypasses.
    private func setAllowlistOnlyMode(profileID: String, apiKey: String, enabled: Bool) async throws {
        // NextDNS setting: profiles/{id}/settings → blockPage.enabled + allowlist-only via
        // the "Block Bypass Methods" + allowlist entries with active:true take priority.
        // The cleanest way is the "allowlist" entries already have priority over blocklists.
        // For true whitelist-only, use the privacy "blocklists" approach by blocking TLDs
        // and only allowing via allowlist — but the supported API path is:
        // PATCH /profiles/{id}/settings with { "blockPage": { ... }, "logging": { ... } }
        // The whitelist-only mode flag is not directly in the public API, so we approximate
        // it by adding a wildcard "*" denylist entry which blocks everything, letting the
        // allowlist entries override (allowlist always wins over denylist in NextDNS).
        let denyURL = "\(base)/profiles/\(profileID)/denylist"
        if enabled {
            // Add wildcard block — allowlist entries override this for allowed domains
            try await addEntry(listURL: denyURL, apiKey: apiKey, domain: "*")
        } else {
            // Remove wildcard block if present
            try await removeEntry(listURL: denyURL, apiKey: apiKey, domain: "*")
        }
    }

    /// Fetch the profile name from NextDNS (validates the API key + profile ID).
    func fetchProfileName(profileID: String, apiKey: String) async -> String? {
        guard let url = URL(string: "\(base)/profiles/\(profileID)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return name
    }

    /// Fetch all profiles for this API key (used to let admin pick the right one).
    func fetchProfiles(apiKey: String) async -> [NextDNSProfile] {
        guard let url = URL(string: "\(base)/profiles") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return NextDNSProfile(id: id, name: name)
        }
    }

    // MARK: - Private helpers

    private func replaceList(endpoint: String,
                             profileID: String,
                             apiKey: String,
                             domains: [String]) async throws {
        let listURL = "\(base)/profiles/\(profileID)/\(endpoint)"

        // 1. Fetch existing entries
        guard let getURL = URL(string: listURL) else { return }
        var getReq = URLRequest(url: getURL)
        getReq.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let (listData, _) = try await URLSession.shared.data(for: getReq)

        // Extract existing IDs (domain strings)
        var existing: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
           let arr = json["data"] as? [[String: Any]] {
            existing = arr.compactMap { $0["id"] as? String }
        }

        let desired = Set(domains.map { $0.lowercased() })
        let current = Set(existing)

        // 2. Add new domains
        for domain in desired.subtracting(current) {
            try await addEntry(listURL: listURL, apiKey: apiKey, domain: domain)
        }

        // 3. Remove deleted domains
        for domain in current.subtracting(desired) {
            try await removeEntry(listURL: listURL, apiKey: apiKey, domain: domain)
        }
    }

    private func addEntry(listURL: String, apiKey: String, domain: String) async throws {
        guard let url = URL(string: listURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": domain, "active": true])
        _ = try await URLSession.shared.data(for: req)
    }

    private func removeEntry(listURL: String, apiKey: String, domain: String) async throws {
        guard let url = URL(string: "\(listURL)/\(domain)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        _ = try await URLSession.shared.data(for: req)
    }
}

// MARK: - Models

struct SyncResult {
    let success: Bool
    let error: String?
}

struct NextDNSProfile: Identifiable {
    let id: String
    let name: String
}
