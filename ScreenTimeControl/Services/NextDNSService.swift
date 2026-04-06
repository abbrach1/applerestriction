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

    // MARK: - Sync (called from Apply Website Settings)

    func sync(profileID: String,
              apiKey: String,
              allowedDomains: [String],
              blockedDomains: [String],
              whitelistMode: Bool = false) async -> SyncResult {
        guard !profileID.isEmpty, !apiKey.isEmpty else {
            return SyncResult(success: false, error: "Profile ID or API key missing")
        }
        do {
            try await replaceList(endpoint: "allowlist", profileID: profileID, apiKey: apiKey, domains: allowedDomains)
            try await replaceList(endpoint: "denylist",  profileID: profileID, apiKey: apiKey, domains: blockedDomains)
            try await setAllowlistOnlyMode(profileID: profileID, apiKey: apiKey,
                                           enabled: whitelistMode && !allowedDomains.isEmpty)
            return SyncResult(success: true, error: nil)
        } catch {
            return SyncResult(success: false, error: error.localizedDescription)
        }
    }

    // MARK: - Logs

    /// Fetch the most recent DNS query logs for a profile.
    func fetchLogs(profileID: String, apiKey: String, limit: Int = 100) async -> [DNSLogEntry] {
        guard let url = URL(string: "\(base)/profiles/\(profileID)/logs?limit=\(limit)") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter() // fallback without fractional seconds

        return arr.compactMap { entry in
            guard let domain = entry["domain"] as? String else { return nil }
            let blocked = entry["blocked"] as? Bool ?? false
            let tsStr = entry["timestamp"] as? String ?? ""
            let timestamp = iso.date(from: tsStr) ?? iso2.date(from: tsStr) ?? Date()
            let deviceName = (entry["device"] as? [String: Any])?["name"] as? String ?? ""
            let reason = (entry["reason"] as? [String: Any])?["name"] as? String ?? ""
            return DNSLogEntry(timestamp: timestamp, domain: domain, blocked: blocked,
                               deviceName: deviceName, reason: reason)
        }
    }

    // MARK: - Per-User Allow / Block List Management

    func fetchList(_ endpoint: String, profileID: String, apiKey: String) async -> [DNSListEntry] {
        guard let url = URL(string: "\(base)/profiles/\(profileID)/\(endpoint)") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return DNSListEntry(id: id, active: d["active"] as? Bool ?? true)
        }
    }

    func addDomain(_ domain: String, to endpoint: String, profileID: String, apiKey: String) async throws {
        try await addEntry(listURL: "\(base)/profiles/\(profileID)/\(endpoint)", apiKey: apiKey, domain: domain)
    }

    func removeDomain(_ domain: String, from endpoint: String, profileID: String, apiKey: String) async throws {
        try await removeEntry(listURL: "\(base)/profiles/\(profileID)/\(endpoint)", apiKey: apiKey, domain: domain)
    }

    // MARK: - Profile Info

    func fetchProfileName(profileID: String, apiKey: String) async -> String? {
        guard let url = URL(string: "\(base)/profiles/\(profileID)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return name
    }

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

    private func setAllowlistOnlyMode(profileID: String, apiKey: String, enabled: Bool) async throws {
        let denyURL = "\(base)/profiles/\(profileID)/denylist"
        if enabled {
            try await addEntry(listURL: denyURL, apiKey: apiKey, domain: "*")
        } else {
            try await removeEntry(listURL: denyURL, apiKey: apiKey, domain: "*")
        }
    }

    private func replaceList(endpoint: String, profileID: String, apiKey: String, domains: [String]) async throws {
        let listURL = "\(base)/profiles/\(profileID)/\(endpoint)"
        guard let getURL = URL(string: listURL) else { return }
        var getReq = URLRequest(url: getURL)
        getReq.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let (listData, _) = try await URLSession.shared.data(for: getReq)
        var existing: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
           let arr = json["data"] as? [[String: Any]] {
            existing = arr.compactMap { $0["id"] as? String }
        }
        let desired = Set(domains.map { $0.lowercased() })
        let current = Set(existing)
        for domain in desired.subtracting(current) { try await addEntry(listURL: listURL, apiKey: apiKey, domain: domain) }
        for domain in current.subtracting(desired) { try await removeEntry(listURL: listURL, apiKey: apiKey, domain: domain) }
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

struct DNSLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let domain: String
    let blocked: Bool
    let deviceName: String
    let reason: String
}

struct DNSListEntry: Identifiable {
    let id: String  // domain
    let active: Bool
}
