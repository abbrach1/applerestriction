import Foundation
import FamilyControls

/// Shared UserDefaults wrapper for communicating between the main app and extensions via App Groups
class SharedDefaults {
    static let shared = SharedDefaults()

    private let suiteName = "group.com.screentime.control"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - FamilyActivitySelection

    func saveSelection(_ selection: FamilyActivitySelection, forKey key: String) {
        if let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: key)
        }
    }

    func loadSelection(forKey key: String) -> FamilyActivitySelection? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    // MARK: - Configuration

    func saveConfiguration(_ config: ScreenTimeConfiguration) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: "screentime.configuration")
        }
    }

    func loadConfiguration() -> ScreenTimeConfiguration? {
        guard let data = defaults.data(forKey: "screentime.configuration") else { return nil }
        return try? JSONDecoder().decode(ScreenTimeConfiguration.self, from: data)
    }

    // MARK: - Convenience Keys

    static let blockedAppsKey = "selection.blockedApps"
    static let alwaysAllowedKey = "selection.alwaysAllowed"
}
