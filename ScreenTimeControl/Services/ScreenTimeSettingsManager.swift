#if !targetEnvironment(simulator)

import Foundation
import ManagedSettings
import FamilyControls
import DeviceActivity
import Combine

/// Manages the actual Screen Time restrictions on the device using ManagedSettings
@MainActor
class ScreenTimeSettingsManager: ObservableObject {
    static let shared = ScreenTimeSettingsManager()

    private let store = ManagedSettingsStore()
    private let center = DeviceActivityCenter()

    @Published var selectedAppsToBlock = FamilyActivitySelection()
    @Published var selectedAppsAlwaysAllowed = FamilyActivitySelection()
    @Published var configuration = ScreenTimeConfiguration()
    @Published var isDowntimeActive: Bool = false

    private init() {
        loadSavedConfiguration()
    }

    // MARK: - App Blocking

    /// Block the currently selected apps and categories
    func applyAppRestrictions() {
        let applications = selectedAppsToBlock.applicationTokens
        let categories = selectedAppsToBlock.categoryTokens

        store.shield.applications = applications.isEmpty ? nil : applications
        store.shield.applicationCategories = categories.isEmpty
            ? nil
            : .specific(categories)
        store.shield.webDomainCategories = categories.isEmpty
            ? nil
            : .specific(categories)

        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    /// Remove all app restrictions
    func clearAppRestrictions() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil

        selectedAppsToBlock = FamilyActivitySelection()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Downtime / Device Activity Scheduling

    /// Set a downtime schedule that blocks apps during specified hours
    func setDowntimeSchedule(_ schedule: DowntimeSchedule) {
        configuration.downtimeSchedule = schedule
        configuration.downtimeEnabled = true

        let activityName = DeviceActivityName("screentime.downtime")
        let activitySchedule = DeviceActivitySchedule(
            intervalStart: schedule.startTime,
            intervalEnd: schedule.endTime,
            repeats: true
        )

        do {
            try center.startMonitoring(activityName, during: activitySchedule)
            isDowntimeActive = true
        } catch {
            print("Failed to start downtime monitoring: \(error)")
        }

        saveConfiguration()
    }

    /// Disable the downtime schedule
    func disableDowntime() {
        let activityName = DeviceActivityName("screentime.downtime")
        center.stopMonitoring([activityName])
        configuration.downtimeEnabled = false
        isDowntimeActive = false
        saveConfiguration()
    }

    // MARK: - Time Limits

    /// Set a time limit for monitored activity
    func setTimeLimit(minutes: Int, for activityName: String) {
        let name = DeviceActivityName(activityName)
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())

        var endComponents = now
        endComponents.hour = 23
        endComponents.minute = 59

        let schedule = DeviceActivitySchedule(
            intervalStart: now,
            intervalEnd: endComponents,
            repeats: true
        )

        let event = DeviceActivityEvent(
            applications: selectedAppsToBlock.applicationTokens,
            categories: selectedAppsToBlock.categoryTokens,
            threshold: DateComponents(minute: minutes)
        )

        do {
            try center.startMonitoring(
                name,
                during: schedule,
                events: [DeviceActivityEvent.Name("limit.\(activityName)"): event]
            )
        } catch {
            print("Failed to set time limit: \(error)")
        }

        saveConfiguration()
    }

    // MARK: - Always Allowed Apps

    /// Update the list of apps that are always allowed (even during downtime)
    func updateAlwaysAllowed() {
        // Clear existing shields for always-allowed apps
        // The ManagedSettingsStore handles this by not shielding these apps
        saveConfiguration()
    }

    // MARK: - Lock / Unlock All

    /// Lock the device by blocking all app categories
    func lockAllApps() {
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    /// Remove all restrictions
    func unlockAll() {
        store.clearAllSettings()
        configuration.downtimeEnabled = false
        isDowntimeActive = false
        selectedAppsToBlock = FamilyActivitySelection()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Apply Remote Configuration

    /// Apply a configuration received from the remote server
    func applyRemoteConfiguration(_ config: ScreenTimeConfiguration) {
        configuration = config

        if config.downtimeEnabled {
            setDowntimeSchedule(config.downtimeSchedule)
        } else {
            disableDowntime()
        }

        // Re-apply app restrictions
        applyAppRestrictions()
    }

    // MARK: - Persistence

    private func saveConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: "screentime.configuration")
        }
    }

    private func loadSavedConfiguration() {
        if let data = UserDefaults.standard.data(forKey: "screentime.configuration"),
           let config = try? JSONDecoder().decode(ScreenTimeConfiguration.self, from: data) {
            configuration = config
        }
    }
}

#endif
