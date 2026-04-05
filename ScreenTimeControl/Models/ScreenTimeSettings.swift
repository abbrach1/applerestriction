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
    var blockedWebsites: [String] = []
    var allowedWebsites: [String] = []
    var websiteFilterMode: WebFilterMode = .blacklist
    var appTimeLimits: [AppTimeLimit] = []
    var downtimeEnabled: Bool = false
    var downtimeSchedule: DowntimeSchedule = DowntimeSchedule()
    var isLocked: Bool = false
}

// Custom decode in extension — preserves synthesized init() and memberwise init
extension ScreenTimeConfiguration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decodeIfPresent(String.self,        forKey: .id)                ?? UUID().uuidString
        deviceId          = try c.decodeIfPresent(String.self,        forKey: .deviceId)          ?? ""
        deviceName        = try c.decodeIfPresent(String.self,        forKey: .deviceName)        ?? ""
        lastUpdated       = try c.decodeIfPresent(Date.self,          forKey: .lastUpdated)       ?? Date()
        blockedApps       = try c.decodeIfPresent(Set<String>.self,   forKey: .blockedApps)       ?? []
        blockedCategories = try c.decodeIfPresent(Set<String>.self,   forKey: .blockedCategories) ?? []
        blockedWebsites   = try c.decodeIfPresent([String].self,      forKey: .blockedWebsites)   ?? []
        allowedWebsites   = try c.decodeIfPresent([String].self,      forKey: .allowedWebsites)   ?? []
        websiteFilterMode = try c.decodeIfPresent(WebFilterMode.self, forKey: .websiteFilterMode) ?? .blacklist
        appTimeLimits     = try c.decodeIfPresent([AppTimeLimit].self, forKey: .appTimeLimits)    ?? []
        downtimeEnabled   = try c.decodeIfPresent(Bool.self,          forKey: .downtimeEnabled)   ?? false
        downtimeSchedule  = try c.decodeIfPresent(DowntimeSchedule.self, forKey: .downtimeSchedule) ?? DowntimeSchedule()
        isLocked          = try c.decodeIfPresent(Bool.self,          forKey: .isLocked)          ?? false
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
