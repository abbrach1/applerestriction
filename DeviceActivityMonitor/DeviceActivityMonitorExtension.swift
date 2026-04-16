import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// Shields the apps / categories a per-app time limit targets as soon as the
/// child's cumulative usage reaches the admin-set threshold for the day.
///
/// The main app configures monitoring via `DeviceActivityCenter.startMonitoring`
/// with one `DeviceActivityName` per limit — `screentime.limit.<id>` — and a
/// matching `DeviceActivityEvent.Name` of `limit.reached.<id>`. When the
/// threshold fires here, we look up the original `FamilyActivitySelection` the
/// main app stored in the shared App Group and shield exactly those apps /
/// categories via a per-limit `ManagedSettingsStore`, so each limit's shield
/// can be cleared independently when the daily interval rolls over.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let appGroupID = "group.com.abbrachfeld.bsafe"

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity.rawValue == "screentime.downtime" {
            let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories   = .all()
        }
        // Per-limit intervals start every midnight — clear any shield from the
        // previous day so the child gets their fresh daily budget.
        if let id = limitID(for: activity) {
            ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.limit.\(id)"))
                .clearAllSettings()
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity.rawValue == "screentime.downtime" {
            let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
            store.clearAllSettings()
        }
        if let id = limitID(for: activity) {
            ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.limit.\(id)"))
                .clearAllSettings()
        }
    }

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let id = limitID(for: activity) else { return }

        // Pull the original FamilyActivitySelection the admin picked.
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: "bsafe.limit.\(id).selection"),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }

        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.limit.\(id)"))
        if !selection.applicationTokens.isEmpty {
            store.shield.applications = selection.applicationTokens
        }
        if !selection.categoryTokens.isEmpty {
            store.shield.applicationCategories = .specific(selection.categoryTokens)
            store.shield.webDomainCategories   = .specific(selection.categoryTokens)
        }
        if !selection.webDomainTokens.isEmpty {
            store.shield.webDomains = selection.webDomainTokens
        }
    }

    /// Parse `screentime.limit.<id>` activity names back into their UUID.
    private func limitID(for activity: DeviceActivityName) -> String? {
        let prefix = "screentime.limit."
        guard activity.rawValue.hasPrefix(prefix) else { return nil }
        return String(activity.rawValue.dropFirst(prefix.count))
    }
}
