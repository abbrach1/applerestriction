import SwiftUI

#if !targetEnvironment(simulator)
import FamilyControls
#endif

@main
struct ScreenTimeControlApp: App {
    @StateObject private var auth = FirebaseAuthService.shared
    @StateObject private var authManager = ActiveAuthorizationManager.shared
    @StateObject private var settingsManager = ActiveScreenTimeSettingsManager.shared
    @StateObject private var syncService = RemoteSyncService.shared

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
                        // Register device in Firebase when logged in as child
                        if let user = auth.currentUser {
                            await syncService.registerDevice(
                                uid: user.uid,
                                email: user.email,
                                idToken: user.idToken
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
                            let token = await auth.freshToken() ?? user.idToken
                            await syncService.registerDevice(uid: user.uid, email: user.email, idToken: token)
                        }
                        syncService.startPolling()
                    }
            }
        }
    }
}
