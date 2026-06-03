import DeviceActivity
import ManagedSettings
import FamilyControls

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let appGroupID = "group.com.abbrachfeld.bsafe"

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity.rawValue == "screentime.downtime" {
            let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories   = .all()
        }
        // For per-app limits we don't shield at intervalDidStart — only when
        // the threshold is actually reached. This is the whole point of a
        // *daily* limit: the user gets their allotted minutes first.
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity.rawValue == "screentime.downtime" {
            ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime")).clearAllSettings()
            return
        }
        // Daily reset: a per-app limit interval rolls over at midnight, so
        // clear that limit's shield so the user gets a fresh allowance.
        if activity.rawValue.hasPrefix("limit.") {
            let id = String(activity.rawValue.dropFirst("limit.".count))
            ManagedSettingsStore(named: ManagedSettingsStore.Name("limit.\(id)")).clearAllSettings()
        }
    }

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        // Event name is "threshold.<id>"; activity name is "limit.<id>".
        // Decode the original selection blob from the App Group, then
        // shield exactly those tokens (no broader category sweep).
        guard activity.rawValue.hasPrefix("limit.") else { return }
        let id = String(activity.rawValue.dropFirst("limit.".count))

        guard let defaults = UserDefaults(suiteName: appGroupID),
              let base64 = defaults.string(forKey: "bsafe.limit.\(id).selectionData"),
              let data = Data(base64Encoded: base64),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return
        }

        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("limit.\(id)"))
        if !selection.applicationTokens.isEmpty {
            store.shield.applications = selection.applicationTokens
        }
        if !selection.categoryTokens.isEmpty {
            store.shield.applicationCategories =
                ShieldSettings.ActivityCategoryPolicy<Application>.specific(selection.categoryTokens)
            store.shield.webDomainCategories =
                ShieldSettings.ActivityCategoryPolicy<WebDomain>.specific(selection.categoryTokens)
        }
        if !selection.webDomainTokens.isEmpty {
            store.shield.webDomains = selection.webDomainTokens
        }
    }
}
