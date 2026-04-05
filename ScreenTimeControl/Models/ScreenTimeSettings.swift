import Foundation

#if !targetEnvironment(simulator)
import FamilyControls
import ManagedSettings
#endif

// MARK: - Main Configuration

struct ScreenTimeConfiguration: Codable, Identifiable {
    var id: String = UUID().uuidString
    var deviceId: String = ""
    var deviceName: String = ""
    var lastUpdated: Date = Date()

    var blockedApps: Set<String> = []
    var blockedCategories: Set<String> = []
    var blockedAppsSelectionData: String? = nil  // base64 JSON of FamilyActivitySelection
    var blockedWebsites: [String] = []
    var allowedWebsites: [String] = []
    var websiteFilterMode: WebFilterMode = .blacklist
    var appTimeLimits: [AppTimeLimit] = []
    var downtimeEnabled: Bool = false
    var downtimeSchedule: DowntimeSchedule = DowntimeSchedule()
    var isLocked: Bool = false
    var blockNewApps: Bool = false
    var contentBlockerEnabled: Bool = false
    var forceDNS: Bool = false
    var nextDNSProfileID: String = ""       // NextDNS profile ID, e.g. "abc123"
    var nextDNSApiKey: String = ""          // NextDNS API key (admin only)
    var dnsAlertOnRemoval: Bool = true      // notify admin if child removes DNS profile
    var dnsAutoReapply: Bool = true         // automatically re-install DNS profile if removed
}

// Custom decode in extension — preserves synthesized init() and memberwise init
extension ScreenTimeConfiguration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decodeIfPresent(String.self,        forKey: .id)                ?? UUID().uuidString
        deviceId          = try c.decodeIfPresent(String.self,        forKey: .deviceId)          ?? ""
        deviceName        = try c.decodeIfPresent(String.self,        forKey: .deviceName)        ?? ""
        lastUpdated       = try c.decodeIfPresent(Date.self,          forKey: .lastUpdated)       ?? Date()
        blockedApps            = try c.decodeIfPresent(Set<String>.self, forKey: .blockedApps)            ?? []
        blockedCategories      = try c.decodeIfPresent(Set<String>.self, forKey: .blockedCategories)      ?? []
        blockedAppsSelectionData = try c.decodeIfPresent(String.self,   forKey: .blockedAppsSelectionData) ?? nil
        blockedWebsites   = try c.decodeIfPresent([String].self,      forKey: .blockedWebsites)   ?? []
        allowedWebsites   = try c.decodeIfPresent([String].self,      forKey: .allowedWebsites)   ?? []
        websiteFilterMode = try c.decodeIfPresent(WebFilterMode.self, forKey: .websiteFilterMode) ?? .blacklist
        appTimeLimits     = try c.decodeIfPresent([AppTimeLimit].self, forKey: .appTimeLimits)    ?? []
        downtimeEnabled   = try c.decodeIfPresent(Bool.self,          forKey: .downtimeEnabled)   ?? false
        downtimeSchedule  = try c.decodeIfPresent(DowntimeSchedule.self, forKey: .downtimeSchedule) ?? DowntimeSchedule()
        isLocked               = try c.decodeIfPresent(Bool.self,   forKey: .isLocked)               ?? false
        blockNewApps           = try c.decodeIfPresent(Bool.self,   forKey: .blockNewApps)           ?? false
        contentBlockerEnabled  = try c.decodeIfPresent(Bool.self,   forKey: .contentBlockerEnabled)  ?? false
        forceDNS               = try c.decodeIfPresent(Bool.self,   forKey: .forceDNS)               ?? false
        nextDNSProfileID       = try c.decodeIfPresent(String.self, forKey: .nextDNSProfileID)       ?? ""
        nextDNSApiKey          = try c.decodeIfPresent(String.self, forKey: .nextDNSApiKey)          ?? ""
        dnsAlertOnRemoval      = try c.decodeIfPresent(Bool.self,   forKey: .dnsAlertOnRemoval)      ?? true
        dnsAutoReapply         = try c.decodeIfPresent(Bool.self,   forKey: .dnsAutoReapply)         ?? true
    }
}

// MARK: - Website Filter Mode

enum WebFilterMode: String, Codable {
    case blacklist
    case whitelist
}

// MARK: - App Time Limit

struct AppTimeLimit: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var appToken: String
    var displayName: String
    var timeLimitMinutes: Int
    var isCategory: Bool = false
}

// MARK: - Downtime Schedule

struct DowntimeSchedule: Codable, Hashable {
    var startHour: Int = 22
    var startMinute: Int = 0
    var endHour: Int = 7
    var endMinute: Int = 0
    var activeDays: Set<Int> = Set(1...7)

    var startTime: DateComponents {
        var c = DateComponents(); c.hour = startHour; c.minute = startMinute; return c
    }
    var endTime: DateComponents {
        var c = DateComponents(); c.hour = endHour; c.minute = endMinute; return c
    }
}

extension DowntimeSchedule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startHour   = try c.decodeIfPresent(Int.self,      forKey: .startHour)   ?? 22
        startMinute = try c.decodeIfPresent(Int.self,      forKey: .startMinute) ?? 0
        endHour     = try c.decodeIfPresent(Int.self,      forKey: .endHour)     ?? 7
        endMinute   = try c.decodeIfPresent(Int.self,      forKey: .endMinute)   ?? 0
        activeDays  = try c.decodeIfPresent(Set<Int>.self, forKey: .activeDays)  ?? Set(1...7)
    }
}

// MARK: - Remote Command

struct RemoteCommand: Codable, Identifiable {
    var id: String = UUID().uuidString
    var timestamp: Date = Date()
    var type: CommandType
    var payload: [String: String] = [:]
    var executed: Bool = false

    enum CommandType: String, Codable {
        case updateBlockedApps
        case updateDowntime
        case updateTimeLimits
        case updateWebsites
        case lockDevice
        case unlockAll
        case refreshSettings
    }
}

// MARK: - Tamper Alert (child → admin, stored at /users/uid/tamperAlerts/{pushKey})

struct TamperAlert: Codable, Identifiable {
    var id: String = UUID().uuidString
    var type: String = ""       // e.g. "dns_removed"
    var message: String = ""
    var timestamp: Date = Date()
    var dismissed: Bool = false
}

extension TamperAlert {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(String.self, forKey: .id)        ?? UUID().uuidString
        type      = try c.decodeIfPresent(String.self, forKey: .type)      ?? ""
        message   = try c.decodeIfPresent(String.self, forKey: .message)   ?? ""
        timestamp = try c.decodeIfPresent(Date.self,   forKey: .timestamp) ?? Date()
        dismissed = try c.decodeIfPresent(Bool.self,   forKey: .dismissed) ?? false
    }
}

// MARK: - Recommended App (admin → child, stored at /users/uid/pendingApps/{pushKey})

struct RecommendedApp: Codable, Identifiable {
    var id: String = UUID().uuidString
    var appStoreID: String = ""     // numeric trackId as String, e.g. "389801252"
    var appName: String = ""
    var iconURL: String = ""        // artworkUrl100
    var category: String = ""
    var sellerName: String = ""
    var timestamp: Date = Date()
}

extension RecommendedApp {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(String.self, forKey: .id)         ?? UUID().uuidString
        appStoreID = try c.decodeIfPresent(String.self, forKey: .appStoreID) ?? ""
        appName    = try c.decodeIfPresent(String.self, forKey: .appName)    ?? ""
        iconURL    = try c.decodeIfPresent(String.self, forKey: .iconURL)    ?? ""
        category   = try c.decodeIfPresent(String.self, forKey: .category)   ?? ""
        sellerName = try c.decodeIfPresent(String.self, forKey: .sellerName) ?? ""
        timestamp  = try c.decodeIfPresent(Date.self,   forKey: .timestamp)  ?? Date()
    }
}

// MARK: - Admin Notification (admin → child, stored at /users/uid/notifications/{pushKey})

struct AdminNotification: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var timestamp: Date = Date()
}

extension AdminNotification {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(String.self, forKey: .id)        ?? UUID().uuidString
        title     = try c.decodeIfPresent(String.self, forKey: .title)     ?? ""
        body      = try c.decodeIfPresent(String.self, forKey: .body)      ?? ""
        timestamp = try c.decodeIfPresent(Date.self,   forKey: .timestamp) ?? Date()
    }
}

// MARK: - Unlock Request (child → admin, stored at /users/uid/unlockRequests/{autoId})

struct UnlockRequest: Codable, Identifiable {
    var id: String = UUID().uuidString
    var reason: String = ""
    var timestamp: Date = Date()
    var deviceName: String = ""
}

extension UnlockRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(String.self, forKey: .id)         ?? UUID().uuidString
        reason     = try c.decodeIfPresent(String.self, forKey: .reason)     ?? ""
        timestamp  = try c.decodeIfPresent(Date.self,   forKey: .timestamp)  ?? Date()
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
    }
}

// MARK: - App List Report (child → admin, stored at /users/uid/appList)

struct AppListReport: Codable {
    var selectionData: String = ""
    var appCount: Int = 0
    var categoryCount: Int = 0
    var timestamp: Date = Date()
    var reviewed: Bool = false
}

extension AppListReport {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectionData = try c.decodeIfPresent(String.self, forKey: .selectionData) ?? ""
        appCount      = try c.decodeIfPresent(Int.self,    forKey: .appCount)       ?? 0
        categoryCount = try c.decodeIfPresent(Int.self,    forKey: .categoryCount)  ?? 0
        timestamp     = try c.decodeIfPresent(Date.self,   forKey: .timestamp)      ?? Date()
        reviewed      = try c.decodeIfPresent(Bool.self,   forKey: .reviewed)       ?? false
    }
}

extension RemoteCommand {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(String.self,           forKey: .id)        ?? UUID().uuidString
        timestamp = try c.decodeIfPresent(Date.self,             forKey: .timestamp) ?? Date()
        type      = try c.decode(CommandType.self,               forKey: .type)
        payload   = try c.decodeIfPresent([String: String].self, forKey: .payload)   ?? [:]
        executed  = try c.decodeIfPresent(Bool.self,             forKey: .executed)  ?? false
    }
}
