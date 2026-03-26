import DeviceActivity
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    // Use separate named stores so downtime and app-limit shields don't conflict
    private let downtimeStore  = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
    private let limitsStore    = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.appLimits"))

    /// Called when a scheduled interval begins — apply downtime shields
    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        if activity.rawValue == "screentime.downtime" {
            downtimeStore.shield.applicationCategories = .all()
            downtimeStore.shield.webDomainCategories   = .all()
        }
    }

    /// Called when a scheduled interval ends — lift downtime shields
    nonisolated override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        if activity.rawValue == "screentime.downtime" {
            downtimeStore.clearAllSettings()
        }
    }

    /// Called when a usage threshold (time limit) is reached — block the apps
    nonisolated override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        if event.rawValue.hasPrefix("limit.") {
            limitsStore.shield.applicationCategories = .all()
        }
    }
}
