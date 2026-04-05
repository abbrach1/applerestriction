#if !targetEnvironment(simulator)

import Foundation
import ManagedSettings
import FamilyControls
import Combine

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

    // MARK: - Convenience type aliases to avoid inference crashes

    private typealias AppPolicy = ShieldSettings.ActivityCategoryPolicy<Application>
    private typealias WebPolicy = ShieldSettings.ActivityCategoryPolicy<WebDomain>

    // MARK: - App Blocking

    func applyAppRestrictions() {
        let applications = selectedAppsToBlock.applicationTokens
        let categories = selectedAppsToBlock.categoryTokens

        if applications.isEmpty {
            store.shield.applications = nil
        } else {
            store.shield.applications = applications
        }

        if categories.isEmpty {
            store.shield.applicationCategories = nil
            // Do NOT touch webDomainCategories here — managed by applyWebsiteRestrictions
        } else {
            store.shield.applicationCategories = AppPolicy.specific(categories)
            // Only override webDomainCategories for app categories if not already blocking all
            if !isDowntimeActive && configuration.websiteFilterMode == .blacklist && configuration.blockedWebsites.isEmpty {
                store.shield.webDomainCategories = WebPolicy.specific(categories)
            }
        }

        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    func clearAppRestrictions() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        // Do NOT clear webDomainCategories — managed by applyWebsiteRestrictions
        selectedAppsToBlock = FamilyActivitySelection()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Downtime

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
        store.shield.applicationCategories = nil
        // Restore website restriction state instead of blindly clearing
        applyWebsiteRestrictions()
        saveConfiguration()
    }

    private func startDowntimeTimer() {
        downtimeTimer?.invalidate()
        downtimeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.checkAndApplyDowntime()
            }
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
            inDowntime = currentMinutes >= startMinutes || currentMinutes < endMinutes
        }

        if inDowntime && !isDowntimeActive {
            store.shield.applicationCategories = AppPolicy.all()
            store.shield.webDomainCategories = WebPolicy.all()
            isDowntimeActive = true
        } else if !inDowntime && isDowntimeActive {
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
            isDowntimeActive = false
            applyAppRestrictions()
        }
    }

    // MARK: - Time Limits

    func setTimeLimit(minutes: Int, for activityName: String) {
        print("[B-SAFE] Time limit set: \(minutes) min for \(activityName)")
        saveConfiguration()
    }

    // MARK: - Lock / Unlock All

    func lockAllApps() {
        store.shield.applicationCategories = AppPolicy.all()
        store.shield.webDomainCategories = WebPolicy.all()
        isDowntimeActive = true
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    func unlockAll() {
        store.clearAllSettings()
        configuration.downtimeEnabled = false
        configuration.blockNewApps = false
        isDowntimeActive = false
        downtimeTimer?.invalidate()
        selectedAppsToBlock = FamilyActivitySelection()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Website Blocking
    //
    // NOTE: store.shield.webDomains requires opaque WebDomainToken values
    // obtained from FamilyActivitySelection (on-device picker only).
    // Plain domain strings cannot be converted to tokens remotely.
    // Instead we use category-level blocking: any blocked domains → block all web,
    // whitelist mode → block all web. Domain strings are stored for reference.

    func applyWebsiteRestrictions() {
        if configuration.websiteFilterMode == .blacklist {
            // Block all web categories if any domains are in the list;
            // clear if the list is empty (admin explicitly removed all blocks).
            if configuration.blockedWebsites.isEmpty {
                if !isDowntimeActive {
                    store.shield.webDomainCategories = nil
                }
            } else {
                store.shield.webDomainCategories = WebPolicy.all()
            }
        } else {
            // Whitelist mode
            store.shield.webDomains = nil

            // When the admin has set allowedWebsites remotely, the Safari Content Blocker
            // enforces the whitelist (block-all + ignore-previous-rules for allowed domains).
            // ManagedSettings cannot work with plain domain strings — it needs opaque
            // WebDomainTokens from the on-device FamilyActivityPicker. Setting
            // webDomainCategories = .all() here would override the content blocker and
            // block the allowed sites too. So: clear the Screen Time shield and let
            // the content blocker own whitelist enforcement.
            if configuration.contentBlockerEnabled && !configuration.allowedWebsites.isEmpty {
                store.shield.webDomainCategories = nil
                saveConfiguration()
                return
            }

            // On-device picker path: use opaque WebDomainTokens if available
            if let base64 = UserDefaults.standard.string(forKey: "screentime.websiteSelection"),
               let data = Data(base64Encoded: base64),
               let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
                let webTokens = selection.webDomainTokens
                let catTokens = selection.categoryTokens
                if !webTokens.isEmpty {
                    store.shield.webDomainCategories = WebPolicy.all(except: webTokens)
                } else if !catTokens.isEmpty {
                    store.shield.webDomainCategories = nil
                } else {
                    store.shield.webDomainCategories = WebPolicy.all()
                }
            } else {
                store.shield.webDomainCategories = WebPolicy.all()
            }
        }
        saveConfiguration()
    }

    // MARK: - Installation Block Override

    /// When admin pushes apps, temporarily lift denyAppInstallation so they can install.
    /// Called by ChildDeviceView whenever pendingApps list changes.
    func updateInstallationBlock(hasPendingAdminApps: Bool) {
        if hasPendingAdminApps {
            store.application.denyAppInstallation = false
        } else {
            store.application.denyAppInstallation = configuration.blockNewApps
        }
    }

    // MARK: - Remote Configuration

    func applyRemoteConfiguration(_ config: ScreenTimeConfiguration) {
        configuration = config

        if config.isLocked {
            lockAllApps()
            ContentBlockerService.shared.applyRules(for: config)
            Task { if config.forceDNS { await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID) } }
            return
        }

        // Downtime
        if config.downtimeEnabled {
            setDowntimeSchedule(config.downtimeSchedule)
        } else {
            configuration.downtimeEnabled = false
            isDowntimeActive = false
            downtimeTimer?.invalidate()
            downtimeTimer = nil
            store.shield.applicationCategories = nil
        }

        // Decode and apply app selection from remote config
        if let base64 = config.blockedAppsSelectionData,
           let data = Data(base64Encoded: base64),
           let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedAppsToBlock = selection
        } else {
            selectedAppsToBlock = FamilyActivitySelection()
        }

        // App installation blocking
        store.application.denyAppInstallation = config.blockNewApps

        // App restrictions first, website restrictions last (so website blocking isn't overwritten)
        applyAppRestrictions()
        applyWebsiteRestrictions()

        // Content blocker (Safari) + DNS
        if config.contentBlockerEnabled {
            ContentBlockerService.shared.applyRules(for: config)
        } else {
            ContentBlockerService.shared.clearRules()
        }

        Task {
            if config.forceDNS {
                await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID)
            } else {
                await ContentBlockerService.shared.disableForcedDNS()
            }
        }
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
        // Restore app installation block
        store.application.denyAppInstallation = configuration.blockNewApps

        if configuration.downtimeEnabled {
            startDowntimeTimer()
            checkAndApplyDowntime()
        }
        // Restore website blocking (persisted in configuration but not in ManagedSettingsStore)
        if configuration.isLocked {
            store.shield.applicationCategories = AppPolicy.all()
            store.shield.webDomainCategories = WebPolicy.all()
            isDowntimeActive = true
        } else {
            applyWebsiteRestrictions()
        }
    }
}

#endif
