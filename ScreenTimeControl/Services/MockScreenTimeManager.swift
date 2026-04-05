import Foundation
import SwiftUI
import Combine

#if targetEnvironment(simulator)

/// Mock manager for Simulator testing — real Screen Time APIs only work on device
@MainActor
class MockAuthorizationManager: ObservableObject {
    static let shared = MockAuthorizationManager()

    @Published var isAuthorized: Bool = false
    @Published var authorizationError: String?
    @Published var isRequesting: Bool = false

    func requestAuthorization() async {
        isRequesting = true
        // Simulate a short delay
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        isAuthorized = true
        isRequesting = false
    }

    func requestParentAuthorization() async {
        isRequesting = true
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        isAuthorized = true
        isRequesting = false
    }

    func revokeAuthorization() {
        isAuthorized = false
    }
}

@MainActor
class MockScreenTimeSettingsManager: ObservableObject {
    static let shared = MockScreenTimeSettingsManager()

    @Published var configuration = ScreenTimeConfiguration()
    @Published var isDowntimeActive: Bool = false
    @Published var blockedAppCount: Int = 0
    @Published var blockedCategoryCount: Int = 0
    @Published var selectedAppsAlwaysAllowed: Int = 0

    func applyAppRestrictions() {
        print("[SIMULATOR] Would apply app restrictions")
        blockedAppCount = 5  // Fake count for UI testing
        blockedCategoryCount = 2
    }

    func clearAppRestrictions() {
        print("[SIMULATOR] Clearing app restrictions")
        blockedAppCount = 0
        blockedCategoryCount = 0
    }

    func setDowntimeSchedule(_ schedule: DowntimeSchedule) {
        configuration.downtimeSchedule = schedule
        configuration.downtimeEnabled = true
        isDowntimeActive = true
        print("[SIMULATOR] Downtime set: \(schedule.startHour):\(schedule.startMinute) - \(schedule.endHour):\(schedule.endMinute)")
    }

    func disableDowntime() {
        configuration.downtimeEnabled = false
        isDowntimeActive = false
        print("[SIMULATOR] Downtime disabled")
    }

    func setTimeLimit(minutes: Int, for activityName: String) {
        print("[SIMULATOR] Time limit set: \(minutes) min for \(activityName)")
    }

    func lockAllApps() {
        print("[SIMULATOR] All apps locked")
        blockedAppCount = 99
    }

    func unlockAll() {
        print("[SIMULATOR] All apps unlocked")
        blockedAppCount = 0
        blockedCategoryCount = 0
        configuration.downtimeEnabled = false
        isDowntimeActive = false
    }

    func applyWebsiteRestrictions() {
        let config = configuration
        switch config.websiteFilterMode {
        case .blacklist:
            print("[SIMULATOR] Blocking websites: \(config.blockedWebsites)")
        case .whitelist:
            print("[SIMULATOR] Whitelist mode — only allowing: \(config.allowedWebsites)")
        }
    }

    func applyRemoteConfiguration(_ config: ScreenTimeConfiguration) {
        configuration = config
        if config.isLocked {
            lockAllApps()
            return
        }
        if config.downtimeEnabled {
            setDowntimeSchedule(config.downtimeSchedule)
        } else {
            disableDowntime()
        }
        applyWebsiteRestrictions()
        applyAppRestrictions()
        print("[SIMULATOR] Applied remote configuration")
    }
}

#endif
