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

    func setTimeLimit(minutes: Int, for activityName: String) {
        print("[B-SAFE] Time limit set: \(minutes) min for \(activityName)")
        saveConfiguration()
    }

    /// Enforce the current set of per-app time limits.
    ///
    /// Strategy:
    ///   1. Stop monitoring for limits that were removed / disabled / had their
    ///      minutes changed (Screen Time requires a stop + start pair to pick
    ///      up a new threshold).
    ///   2. For each enabled limit, decode its FamilyActivitySelection, write
    ///      it to the shared App Group so the DeviceActivityMonitor extension
    ///      can read it when the threshold fires, and call
    ///      DeviceActivityCenter.startMonitoring with a daily schedule.
    ///   3. Clear any shield from a previous day so the limit starts fresh.
    ///
    /// The extension (DeviceActivityMonitorExtension) is what actually shields
    /// the apps when a threshold is reached; this main-app method only
    /// configures what to monitor.
    func applyAppTimeLimits(_ limits: [AppTimeLimit]) {
        let center = DeviceActivityCenter()
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)

        // Tear down monitors for limits that are no longer active so the
        // extension doesn't keep stale thresholds around.
        let knownIDs = Set(defaults?.stringArray(forKey: "bsafe.limit.ids") ?? [])
        let currentIDs = Set(limits.filter(\.enabled).map(\.id))

        for removedID in knownIDs.subtracting(currentIDs) {
            center.stopMonitoring([.limit(removedID)])
            defaults?.removeObject(forKey: "bsafe.limit.\(removedID).selection")
            defaults?.removeObject(forKey: "bsafe.limit.\(removedID).minutes")
            // Clear any shield the old limit applied.
            ManagedSettingsStore(named: .limit(removedID)).clearAllSettings()
        }
        defaults?.set(Array(currentIDs), forKey: "bsafe.limit.ids")

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0,  minute: 0),
            intervalEnd:   DateComponents(hour: 23, minute: 59),
            repeats: true)

        for limit in limits where limit.enabled && limit.timeLimitMinutes > 0 {
            guard let selectionB64 = limit.selectionData,
                  let data = Data(base64Encoded: selectionB64),
                  let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
                  !(selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty)
            else { continue }

            // Hand the selection to the extension. We store the raw JSON so
            // the extension can decode it into a FamilyActivitySelection too.
            defaults?.set(data, forKey: "bsafe.limit.\(limit.id).selection")
            defaults?.set(limit.timeLimitMinutes, forKey: "bsafe.limit.\(limit.id).minutes")

            let event = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories:   selection.categoryTokens,
                webDomains:   selection.webDomainTokens,
                threshold:    DateComponents(minute: limit.timeLimitMinutes))

            // Make sure yesterday's shield (if any) is cleared so today's
            // budget starts fresh.
            ManagedSettingsStore(named: .limit(limit.id)).clearAllSettings()

            // Restart monitoring with the current threshold. Calling start
            // twice with the same activity name is an error — stop first.
            center.stopMonitoring([.limit(limit.id)])
            do {
                try center.startMonitoring(
                    .limit(limit.id),
                    during: schedule,
                    events: [.limitReached(limit.id): event])
            } catch {
                print("[B-SAFE] startMonitoring failed for \(limit.displayName): \(error)")
            }
        }
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

        // App installation blocking
        store.application.denyAppInstallation = config.blockNewApps

        // App restrictions first, website restrictions last (so website blocking isn't overwritten)
        applyAppRestrictions()
        applyWebsiteRestrictions()
        applyAppTimeLimits(config.appTimeLimits)

        // Safari Content Blocker — always apply rules based on config.
        // This is the DNS-independent enforcement path for Safari. The
        // `contentBlockerEnabled` flag is surfaced to the child as a
        // Safari-settings requirement (they must turn the extension on in
        // Safari → Extensions), but the rules JSON is always kept in sync
        // so the filter is instantly live once enabled.
        ContentBlockerService.shared.applyRules(for: config)

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
