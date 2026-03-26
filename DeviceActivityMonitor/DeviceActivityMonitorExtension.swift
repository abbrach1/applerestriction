import DeviceActivity
import ManagedSettings

/// Extension that monitors device activity and enforces restrictions
/// when time limits are reached or downtime begins
class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    let store = ManagedSettingsStore()

    /// Called when a scheduled activity interval begins (e.g., downtime starts)
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        // When downtime starts, apply shields to all restricted apps
        if activity.rawValue == "screentime.downtime" {
            applyDowntimeRestrictions()
        }
    }

    /// Called when a scheduled activity interval ends (e.g., downtime ends)
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // When downtime ends, remove the downtime shields
        if activity.rawValue == "screentime.downtime" {
            removeDowntimeRestrictions()
        }
    }

    /// Called when a usage threshold is reached (e.g., time limit hit)
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        // When a time limit is reached, block the apps
        if event.rawValue.hasPrefix("limit.") {
            applyTimeLimitRestrictions()
        }
    }

    /// Called when usage drops below a previously reached threshold
    override func eventWillReverseThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventWillReverseThreshold(event, activity: activity)
        // This happens at the start of a new day — reset the limits
    }

    // MARK: - Restriction Helpers

    private func applyDowntimeRestrictions() {
        // Block all app categories during downtime
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
    }

    private func removeDowntimeRestrictions() {
        // Remove downtime shields — user-set blocked apps remain via main store
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
    }

    private func applyTimeLimitRestrictions() {
        // Block all monitored apps when time limit is reached
        store.shield.applicationCategories = .all()
    }
}
