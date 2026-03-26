import SwiftUI
import FamilyControls

@main
struct ScreenTimeControlApp: App {
    @StateObject private var authManager = AuthorizationManager.shared
    @StateObject private var settingsManager = ScreenTimeSettingsManager.shared
    @StateObject private var syncService = RemoteSyncService.shared

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthorized {
                MainTabView()
                    .environmentObject(authManager)
                    .environmentObject(settingsManager)
                    .environmentObject(syncService)
            } else {
                AuthorizationView()
                    .environmentObject(authManager)
            }
        }
    }
}
