#if !targetEnvironment(simulator)

import Foundation
import ManagedSettings
import FamilyControls
import DeviceActivity
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
            applyWebsiteRestrictions() // restore webContent.blockedByFilter
        }
    }

    // MARK: - Time Limits
    //
    // Per-app daily limits use DeviceActivityCenter to monitor usage of
    // each selection and fire `eventDidReachThreshold` on the
    // DeviceActivityMonitor extension once the configured minutes are
    // exceeded. The extension reads the same selection blob back from
    // the App Group and adds the app's tokens to a per-limit
    // ManagedSettingsStore shield, which iOS enforces until midnight
    // when `intervalDidEnd` clears the store.

    private static let appGroupID = "group.com.abbrachfeld.bsafe"

    func applyAppTimeLimits() {
        let center = DeviceActivityCenter()
        let limits = configuration.appTimeLimits.filter { $0.timeLimitMinutes > 0 }

        // First, remove monitoring for any limit ID that is no longer present.
        // Persist the active ID list so we know what to compare against next time.
        let groupDefaults = UserDefaults(suiteName: Self.appGroupID)
        let previousIDs = Set(groupDefaults?.stringArray(forKey: "bsafe.limits.activeIDs") ?? [])
        let currentIDs  = Set(limits.map { $0.id })

        for staleID in previousIDs.subtracting(currentIDs) {
            center.stopMonitoring([DeviceActivityName("limit.\(staleID)")])
            groupDefaults?.removeObject(forKey: "bsafe.limit.\(staleID).selectionData")
            groupDefaults?.removeObject(forKey: "bsafe.limit.\(staleID).displayName")
            // Best-effort: clear any shield this limit had previously set.
            ManagedSettingsStore(named: ManagedSettingsStore.Name("limit.\(staleID)")).clearAllSettings()
        }

        // Daily 00:00 → 23:59 schedule, repeats every day.
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0,  minute: 0),
            intervalEnd:   DateComponents(hour: 23, minute: 59),
            repeats: true
        )

        for limit in limits {
            // Decode the selection so we can pass the right tokens into the event.
            guard let data = Data(base64Encoded: limit.selectionData),
                  let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
                continue
            }

            let event = DeviceActivityEvent(
                applications:      selection.applicationTokens,
                categories:        selection.categoryTokens,
                webDomains:        selection.webDomainTokens,
                threshold:         DateComponents(
                    hour:   limit.timeLimitMinutes / 60,
                    minute: limit.timeLimitMinutes % 60
                )
            )

            // Persist the selection so the monitor extension can re-build the
            // same token set at eventDidReachThreshold time.
            groupDefaults?.set(limit.selectionData, forKey: "bsafe.limit.\(limit.id).selectionData")
            groupDefaults?.set(limit.displayName,   forKey: "bsafe.limit.\(limit.id).displayName")

            do {
                try center.startMonitoring(
                    DeviceActivityName("limit.\(limit.id)"),
                    during: schedule,
                    events: [DeviceActivityEvent.Name("threshold.\(limit.id)"): event]
                )
            } catch {
                print("[B-SAFE] startMonitoring failed for limit \(limit.id): \(error)")
            }
        }

        groupDefaults?.set(Array(currentIDs), forKey: "bsafe.limits.activeIDs")
    }

    /// Stop monitoring all per-app limits — used on full reset / unlockAll.
    func clearAppTimeLimits() {
        let center = DeviceActivityCenter()
        let groupDefaults = UserDefaults(suiteName: Self.appGroupID)
        let ids = groupDefaults?.stringArray(forKey: "bsafe.limits.activeIDs") ?? []
        for id in ids {
            center.stopMonitoring([DeviceActivityName("limit.\(id)")])
            groupDefaults?.removeObject(forKey: "bsafe.limit.\(id).selectionData")
            groupDefaults?.removeObject(forKey: "bsafe.limit.\(id).displayName")
            ManagedSettingsStore(named: ManagedSettingsStore.Name("limit.\(id)")).clearAllSettings()
        }
        groupDefaults?.removeObject(forKey: "bsafe.limits.activeIDs")
    }

    /// Legacy API — kept so older call sites still compile. Real enforcement
    /// is now driven by `applyAppTimeLimits()` reading `configuration.appTimeLimits`.
    func setTimeLimit(minutes: Int, for activityName: String) {
        print("[B-SAFE] setTimeLimit is a no-op stub; use configuration.appTimeLimits instead")
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
        clearAppTimeLimits()
        configuration.lastUpdated = Date()
        saveConfiguration()
    }

    // MARK: - Website Blocking
    //
    // Strategy: store.webContent.blockedByFilter = .blocked routes ALL web traffic
    // (Safari, WKWebView, etc.) through the BSAFEContentFilter NEFilterDataProvider
    // extension. The extension reads the domain lists from the shared App Group and
    // makes per-domain allow/block decisions using plain strings from Firebase.
    //
    // We cannot use .onlyAllow(webDomainTokens:) because that API requires opaque
    // WebDomainToken values from a FamilyActivityPicker — plain domain strings
    // received from the admin over Firebase cannot be converted to tokens.
    //
    // .blocked also acts as a safety net: if NEFilter is not running, all web is
    // blocked rather than leaking through unfiltered.

    func applyWebsiteRestrictions() {
        guard !isDowntimeActive else { return }
        // NEFilter (BSAFEContentFilter extension) handles per-domain allow/block.
        // It is enabled/disabled via ContentFilterService.enable()/disable() separately.
        // Clear any shield-level web blocks so they don't conflict.
        store.shield.webDomainCategories = nil
        store.shield.webDomains = nil
        saveConfiguration()
    }

    // MARK: - Installation Block

    func updateInstallationBlock(hasPendingAdminApps: Bool) {
        // When admin pushes apps, temporarily lift denyAppInstallation so SKOverlay can install.
        // The App Store app itself stays hidden from home screen via shield.applications if blocked there.
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
            Task {
                if config.forceDNS { await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID, removalPassword: config.dnsRemovalPassword) }
                await ContentFilterService.shared.enable(config: config)
            }
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

        // App installation blocking — keep the gate open whenever the admin has
        // pushed apps for the child to install, otherwise SKOverlay's GET button
        // fails because denyAppInstallation blocks all StoreKit purchases.
        let hasPendingAdminApps = !RemoteSyncService.shared.pendingApps.isEmpty
        store.application.denyAppInstallation = hasPendingAdminApps ? false : config.blockNewApps

        // App restrictions first, website restrictions last (so website blocking isn't overwritten)
        applyAppRestrictions()
        applyWebsiteRestrictions()
        applyAppTimeLimits()

        // Content blocker (Safari) + DNS
        if config.contentBlockerEnabled {
            ContentBlockerService.shared.applyRules(for: config)
        } else {
            ContentBlockerService.shared.clearRules()
        }

        Task {
            if config.forceDNS {
                await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID, removalPassword: config.dnsRemovalPassword)
            } else {
                await ContentBlockerService.shared.disableForcedDNS()
            }
            // Content filter: enable whenever there are website restrictions or device is locked
            let hasWebRestrictions = !config.blockedWebsites.isEmpty || config.websiteFilterMode == .whitelist
            if hasWebRestrictions || config.isLocked {
                await ContentFilterService.shared.enable(config: config)
            } else {
                await ContentFilterService.shared.disable()
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
