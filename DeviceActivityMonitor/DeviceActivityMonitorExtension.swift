@preconcurrency import DeviceActivity
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    // Explicit nonisolated init matches the superclass's nonisolated init
    nonisolated override init() {
        super.init()
    }

    nonisolated override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard activity.rawValue == "screentime.downtime" else { return }
        Task { @MainActor in
            let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories   = .all()
        }
    }

    nonisolated override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity.rawValue == "screentime.downtime" else { return }
        Task { @MainActor in
            let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.downtime"))
            store.clearAllSettings()
        }
    }

    nonisolated override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        guard event.rawValue.hasPrefix("limit.") else { return }
        Task { @MainActor in
            let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("screentime.appLimits"))
            store.shield.applicationCategories = .all()
        }
    }
}
