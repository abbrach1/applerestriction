import SwiftUI
import FirebaseCore
import FirebaseDatabase

#if !targetEnvironment(simulator)
import FamilyControls
#endif

@main
struct ScreenTimeControlApp: App {
    @StateObject private var auth = FirebaseAuthService.shared
    @StateObject private var authManager = ActiveAuthorizationManager.shared
    @StateObject private var settingsManager = ActiveScreenTimeSettingsManager.shared
    @StateObject private var syncService = RemoteSyncService.shared

    init() {
        FirebaseApp.configure()
        // Must be set before any Database reference is accessed
        Database.database().isPersistenceEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            if !auth.isLoggedIn {
                LoginView()
                    .environmentObject(auth)
            } else if auth.isAdmin && !authManager.isAuthorized {
                AuthorizationView()
                    .environmentObject(authManager)
                    .environmentObject(auth)
            } else if auth.isAdmin {
                AdminDashboardView()
                    .environmentObject(auth)
                    .environmentObject(authManager)
            } else if !authManager.isAuthorized {
                AuthorizationView()
                    .environmentObject(authManager)
                    .environmentObject(auth)
                    .task {
                        if let user = auth.currentUser {
                            await syncService.registerDevice(
                                uid: user.uid,
                                email: user.email,
                                idToken: ""
                            )
                        }
                    }
            } else {
                ChildDeviceView()
                    .environmentObject(auth)
                    .environmentObject(syncService)
                    .environmentObject(settingsManager)
                    .task {
                        syncService.requestNotificationPermission()
                        if let user = auth.currentUser {
                            await syncService.registerDevice(
                                uid: user.uid,
                                email: user.email,
                                idToken: ""
                            )
                        }
                        syncService.startListening()
                    }
            }
        }
    }
}
