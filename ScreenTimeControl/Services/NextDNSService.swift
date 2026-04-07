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

    // MARK: - Fetch Parental Control State

    /// Fetches the current parental control state from NextDNS (safeSearch, youtubeRestricted, blocked services/categories).
    func fetchParentalControlState(profileID: String, apiKey: String) async -> (safeSearch: Bool, youtubeRestricted: Bool, services: [String], categories: [String]) {
        guard let url = URL(string: "\(base)/profiles/\(profileID)/parentalControl") else {
            return (false, false, [], [])
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, false, [], [])
        }
        let safeSearch = json["safeSearch"] as? Bool ?? false
        let youtubeRestricted = json["youtubeRestrictedMode"] as? Bool ?? false

        // GET services
        var services: [String] = []
        if let servicesURL = URL(string: "\(base)/profiles/\(profileID)/parentalControl/services") {
            var sreq = URLRequest(url: servicesURL)
            sreq.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            if let (sdata, _) = try? await URLSession.shared.data(for: sreq),
               let sjson = try? JSONSerialization.jsonObject(with: sdata) as? [String: Any],
               let arr = sjson["data"] as? [[String: Any]] {
                services = arr.compactMap { d -> String? in
                    guard d["active"] as? Bool == true else { return nil }
                    return d["id"] as? String
                }
            }
        }

        // GET categories
        var categories: [String] = []
        if let catURL = URL(string: "\(base)/profiles/\(profileID)/parentalControl/categories") {
            var creq = URLRequest(url: catURL)
            creq.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            if let (cdata, _) = try? await URLSession.shared.data(for: creq),
               let cjson = try? JSONSerialization.jsonObject(with: cdata) as? [String: Any],
               let arr = cjson["data"] as? [[String: Any]] {
                categories = arr.compactMap { d -> String? in
                    guard d["active"] as? Bool == true else { return nil }
                    return d["id"] as? String
                }
            }
        }
        return (safeSearch, youtubeRestricted, services, categories)
    }

    // MARK: - Parental Control

    /// Applies SafeSearch, YouTube Restricted Mode, and blocked services/categories
    /// to the given NextDNS profile via the Parental Control API.
    func applyParentalControl(profileID: String,
                              apiKey: String,
                              safeSearch: Bool,
                              youtubeRestricted: Bool,
                              blockedServices: [String],
                              blockedCategories: [String]) async {
        guard !profileID.isEmpty, !apiKey.isEmpty else { return }

        // 1. SafeSearch + YouTube via PATCH on parentalControl
        let body: [String: Any] = ["safeSearch": safeSearch, "youtubeRestrictedMode": youtubeRestricted]
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let url = URL(string: "\(base)/profiles/\(profileID)/parentalControl") {
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            _ = try? await URLSession.shared.data(for: req)
        }

        // 2. Sync blocked services
        await syncPCList(profileID: profileID, apiKey: apiKey, listPath: "services",
                         activeIDs: Set(blockedServices),
                         knownIDs: Set(PCItem.knownServices.map { $0.id }))

        // 3. Sync blocked categories
        await syncPCList(profileID: profileID, apiKey: apiKey, listPath: "categories",
                         activeIDs: Set(blockedCategories),
                         knownIDs: Set(PCItem.knownCategories.map { $0.id }))
    }

    private func syncPCList(profileID: String, apiKey: String, listPath: String,
                            activeIDs: Set<String>, knownIDs: Set<String>) async {
        guard let url = URL(string: "\(base)/profiles/\(profileID)/parentalControl/\(listPath)") else { return }
        var getReq = URLRequest(url: url)
        getReq.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        guard let (data, _) = try? await URLSession.shared.data(for: getReq),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return }

        let currentlyBlocked = Set(arr.compactMap { dict -> String? in
            guard dict["active"] as? Bool == true else { return nil }
            return dict["id"] as? String
        })

        // Add what should be blocked but isn't.
        // POST to the collection URL with {"id": ..., "active": true} — same pattern as allowlist/denylist.
        if let collectionURL = URL(string: "\(base)/profiles/\(profileID)/parentalControl/\(listPath)") {
            for id in activeIDs where !currentlyBlocked.contains(id) {
                var req = URLRequest(url: collectionURL)
                req.httpMethod = "POST"
                req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "active": true])
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        // Remove what's blocked but shouldn't be (only items we manage)
        for id in currentlyBlocked where knownIDs.contains(id) && !activeIDs.contains(id) {
            if let delURL = URL(string: "\(base)/profiles/\(profileID)/parentalControl/\(listPath)/\(id)") {
                var req = URLRequest(url: delURL); req.httpMethod = "DELETE"
                req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
                _ = try? await URLSession.shared.data(for: req)
            }
        }
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

struct PCItem: Identifiable {
    let id: String      // NextDNS API ID
    let label: String
    let icon: String    // SF Symbol name

    static let knownServices: [PCItem] = [
        PCItem(id: "tiktok",     label: "TikTok",          icon: "music.note"),
        PCItem(id: "instagram",  label: "Instagram",        icon: "camera"),
        PCItem(id: "snapchat",   label: "Snapchat",         icon: "camera.viewfinder"),
        PCItem(id: "facebook",   label: "Facebook",         icon: "person.2"),
        PCItem(id: "discord",    label: "Discord",          icon: "gamecontroller"),
        PCItem(id: "whatsapp",   label: "WhatsApp",         icon: "bubble.left"),
        PCItem(id: "twitch",     label: "Twitch",           icon: "tv"),
        PCItem(id: "youtube",    label: "YouTube",          icon: "play.rectangle"),
    ]

    static let knownCategories: [PCItem] = [
        PCItem(id: "porn",            label: "Adult Content",   icon: "exclamationmark.shield"),
        PCItem(id: "gambling",        label: "Gambling",        icon: "dollarsign.circle"),
        PCItem(id: "dating",          label: "Dating",          icon: "heart"),
        PCItem(id: "piracy",          label: "Piracy",          icon: "lock.slash"),
        PCItem(id: "social-networks", label: "Social Networks", icon: "network"),
        PCItem(id: "video-streaming", label: "Video Streaming", icon: "play.circle"),
    ]
}
