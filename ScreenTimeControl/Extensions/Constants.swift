#if !targetEnvironment(simulator)

import Foundation
import ManagedSettings
import DeviceActivity

/// Shared constants used across the main app and extensions
enum AppConstants {
    static let appGroupIdentifier = "group.com.abbrachfeld.bsafe"
    static let bundleIdentifier = "com.abbrachfeld.screentimecontrolabbrach"
}

extension ManagedSettingsStore.Name {
    static let downtime = Self("screentime.downtime")
    static let appLimits = Self("screentime.appLimits")
    /// Per-limit ManagedSettings store, keyed off the AppTimeLimit.id.
    /// Each app-time-limit gets its own store so the shields it applies can be
    /// cleared independently without affecting other limits.
    static func limit(_ id: String) -> Self { Self("screentime.limit.\(id)") }
}

extension DeviceActivityName {
    static let dailyDowntime = Self("screentime.downtime")
    static let dailyLimit = Self("screentime.dailyLimit")
    /// One DeviceActivity per configured app-time-limit so thresholds fire
    /// independently per app/category.
    static func limit(_ id: String) -> Self { Self("screentime.limit.\(id)") }
}

extension DeviceActivityEvent.Name {
    static let dailyTimeLimitReached = Self("limit.daily")
    static func limitReached(_ id: String) -> Self { Self("limit.reached.\(id)") }
}

#endif
