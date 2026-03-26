import Foundation

#if !targetEnvironment(simulator)
import FamilyControls
import ManagedSettings
#endif

/// Represents a complete set of Screen Time restrictions that can be synced remotely
struct ScreenTimeConfiguration: Codable, Identifiable {
    var id: String = UUID().uuidString
    var deviceId: String = ""
    var deviceName: String = ""
    var lastUpdated: Date = Date()

    // App Restrictions
    var blockedApps: Set<String> = []       // Bundle identifier tokens
    var blockedCategories: Set<String> = [] // Category tokens

    // Time Limits
    var appTimeLimits: [AppTimeLimit] = []

    // Downtime
    var downtimeEnabled: Bool = false
    var downtimeSchedule: DowntimeSchedule = DowntimeSchedule()

    // Shield settings
    var shieldApps: Bool = true
    var shieldWebDomains: Bool = true
}

struct AppTimeLimit: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var appToken: String   // Encoded app/category token
    var displayName: String
    var timeLimitMinutes: Int
    var isCategory: Bool = false
}

struct DowntimeSchedule: Codable, Hashable {
    var startHour: Int = 22    // 10 PM
    var startMinute: Int = 0
    var endHour: Int = 7       // 7 AM
    var endMinute: Int = 0
    var activeDays: Set<Int> = Set(1...7) // 1=Sunday, 7=Saturday

    var startTime: DateComponents {
        var components = DateComponents()
        components.hour = startHour
        components.minute = startMinute
        return components
    }

    var endTime: DateComponents {
        var components = DateComponents()
        components.hour = endHour
        components.minute = endMinute
        return components
    }
}

/// Remote command that can be sent to a device
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
        case lockDevice
        case unlockAll
        case refreshSettings
    }
}
