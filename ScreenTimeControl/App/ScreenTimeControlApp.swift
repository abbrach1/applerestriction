import SwiftUI

#if !targetEnvironment(simulator)
import FamilyControls
#endif

@main
struct ScreenTimeControlApp: App {
    @StateObject private var authManager = ActiveAuthorizationManager.shared
    @StateObject private var settingsManager = ActiveScreenTimeSettingsManager.shared
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
