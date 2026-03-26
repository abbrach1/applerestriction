#if !targetEnvironment(simulator)

import Foundation
import ManagedSettings
import DeviceActivity

/// Shared constants used across the main app and extensions
enum AppConstants {
    static let appGroupIdentifier = "group.com.screentime.control"
    static let bundleIdentifier = "com.screentime.control"
}

extension ManagedSettingsStore.Name {
    static let downtime = Self("screentime.downtime")
    static let appLimits = Self("screentime.appLimits")
}

extension DeviceActivityName {
    static let dailyDowntime = Self("screentime.downtime")
    static let dailyLimit = Self("screentime.dailyLimit")
}

extension DeviceActivityEvent.Name {
    static let dailyTimeLimitReached = Self("limit.daily")
}

#endif
