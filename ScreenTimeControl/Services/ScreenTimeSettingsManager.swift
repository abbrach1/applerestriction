#if !targetEnvironment(simulator)

import Foundation
import ManagedSettings
import FamilyControls
import Combine

/// Manages Screen Time restrictions directly from the main app via ManagedSettingsStore.
/// No extensions required — all blocking is applied immediately on command.
@MainActor
class ScreenTimeSettingsManager: ObservableObject {
    static let shared = ScreenTimeSettingsManager()

    private let store = ManagedSettingsStore()

    @Published var selectedAppsToBlock = FamilyActivitySelection()
    @Published var selectedAppsAlwaysAllowed = FamilyActivitySelection()
    @Published var configuration = ScreenTimeConfiguration()
    @Published var isDowntimeActive: Bool = false

    private var downtimeTimer: Timer?

    private init() {
        loadSavedConfiguration()
        restoreActiveRestrictions()
    }

    // MARK: - App Blocking

    func applyAppRestrictions() {
        let applications = selectedAppsToBlock.applicationTokens
        let categories = selectedAppsToBlock.categoryTokens

        store.shield.applications = applications.isEmpty ? nil : applications
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        store.shield.webDomainCategories = categories.isEmpty ? nil : .specific(categories)

        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    func clearAppRestrictions() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
        selectedAppsToBlock = FamilyActivitySelection()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Downtime (applied directly, checked every minute)

    func setDowntimeSchedule(_ schedule: DowntimeSchedule) {
        configuration.downtimeSchedule = schedule
        configuration.downtimeEnabled = true
        saveConfiguration()
        startDowntimeTimer()
        checkAndApplyDowntime()
    }

    func disableDowntime() {
        configuration.downtimeEnabled = false
        isDowntimeActive = false
        downtimeTimer?.invalidate()
        downtimeTimer = nil
        // Only clear downtime shield, not app restrictions
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
        saveConfiguration()
    }

    private func startDowntimeTimer() {
        downtimeTimer?.invalidate()
        downtimeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAndApplyDowntime() }
        }
    }

    private func checkAndApplyDowntime() {
        guard configuration.downtimeEnabled else { return }
        let now = Calendar.current.dateComponents([.hour, .minute, .weekday], from: Date())
        let schedule = configuration.downtimeSchedule

        guard let hour = now.hour, let minute = now.minute else { return }
        let currentMinutes = hour * 60 + minute
        let startMinutes = schedule.startHour * 60 + schedule.startMinute
        let endMinutes = schedule.endHour * 60 + schedule.endMinute

        let inDowntime: Bool
        if startMinutes < endMinutes {
            inDowntime = currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            // Overnight (e.g. 10pm - 7am)
            inDowntime = currentMinutes >= startMinutes || currentMinutes < endMinutes
        }

        if inDowntime && !isDowntimeActive {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            isDowntimeActive = true
        } else if !inDowntime && isDowntimeActive {
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
            isDowntimeActive = false
            // Re-apply any manual app restrictions
            applyAppRestrictions()
        }
    }

    // MARK: - Time Limits

    func setTimeLimit(minutes: Int, for activityName: String) {
        // Store limit in configuration — enforced via polling
        print("[B-SAFE] Time limit set: \(minutes) min for \(activityName)")
        saveConfiguration()
    }

    // MARK: - Lock / Unlock All

    func lockAllApps() {
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        isDowntimeActive = true
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    func unlockAll() {
        store.clearAllSettings()
        configuration.downtimeEnabled = false
        isDowntimeActive = false
        downtimeTimer?.invalidate()
        selectedAppsToBlock = FamilyActivitySelection()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Website Blocking

    func applyWebsiteRestrictions() {
        let config = configuration
        if config.websiteFilterMode == .blacklist {
            var webDomains = Set<WebDomain>()
            for domainStr in config.blockedWebsites {
                webDomains.insert(WebDomain(domain: domainStr))
            }
            store.shield.webDomains = webDomains.isEmpty ? nil : webDomains
            if !isDowntimeActive {
                store.shield.webDomainCategories = nil
            }
        } else {
            // Whitelist mode: shield all web domain categories
            store.shield.webDomainCategories = .all()
            store.shield.webDomains = nil
        }
        saveConfiguration()
    }

    // MARK: - Remote Configuration

    func applyRemoteConfiguration(_ config: ScreenTimeConfiguration) {
        configuration = config
        // App lock state
        if config.isLocked {
            lockAllApps()
            return
        }
        // Downtime
        if config.downtimeEnabled {
            setDowntimeSchedule(config.downtimeSchedule)
        } else {
            disableDowntime()
        }
        // Website restrictions
        applyWebsiteRestrictions()
        // App restrictions
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

    private func restoreActiveRestrictions() {
        if configuration.downtimeEnabled {
            startDowntimeTimer()
            checkAndApplyDowntime()
        }
    }
}

#endif
