import Foundation

#if !targetEnvironment(simulator)
import FamilyControls
import ManagedSettings
#endif

struct ScreenTimeConfiguration: Codable, Identifiable {
    var id: String = UUID().uuidString
    var deviceId: String = ""
    var deviceName: String = ""
    var lastUpdated: Date = Date()

    // App Restrictions
    var blockedApps: Set<String> = []
    var blockedCategories: Set<String> = []

    // Website Blocking
    var blockedWebsites: [String] = []        // Domains to block e.g. "youtube.com"
    var allowedWebsites: [String] = []        // Whitelist mode: only these allowed
    var websiteFilterMode: WebFilterMode = .blacklist

    // Time Limits
    var appTimeLimits: [AppTimeLimit] = []

    // Downtime
    var downtimeEnabled: Bool = false
    var downtimeSchedule: DowntimeSchedule = DowntimeSchedule()

    // Lock state
    var isLocked: Bool = false
}

enum WebFilterMode: String, Codable {
    case blacklist  // Block specific sites, allow everything else
    case whitelist  // Allow only specific sites, block everything else
}

struct AppTimeLimit: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var appToken: String
    var displayName: String
    var timeLimitMinutes: Int
    var isCategory: Bool = false
}

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
