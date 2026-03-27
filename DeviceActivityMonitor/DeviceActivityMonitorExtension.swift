import DeviceActivity
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard activity.rawValue == "screentime.downtime" else { return }
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories   = .all()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity.rawValue == "screentime.downtime" else { return }
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
        store.clearAllSettings()
    }

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        guard event.rawValue.hasPrefix("limit.") else { return }
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.appLimits"))
        store.shield.applicationCategories = .all()
    }
}
