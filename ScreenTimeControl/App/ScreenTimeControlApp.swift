import SwiftUI
import FirebaseCore
import FirebaseDatabase
import BackgroundTasks

#if !targetEnvironment(simulator)
import FamilyControls
#endif

private let bgTaskID = "com.abbrachfeld.screentimecontrolabbrach.dnscheck"

@main
struct ScreenTimeControlApp: App {
    @StateObject private var auth = FirebaseAuthService.shared
    @StateObject private var authManager = ActiveAuthorizationManager.shared
    @StateObject private var settingsManager = ActiveScreenTimeSettingsManager.shared
    @StateObject private var syncService = RemoteSyncService.shared

    init() {
        FirebaseApp.configure()
        Database.database().isPersistenceEnabled = true
        registerBackgroundTask()
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
                            await syncService.registerDevice(uid: user.uid, email: user.email, idToken: "")
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
                            await syncService.registerDevice(uid: user.uid, email: user.email, idToken: "")
                        }
                        syncService.startListening()
                        scheduleBackgroundDNSCheck()
                    }
            }
        }
    }

    // MARK: - Background DNS Check

    /// Register the background task handler. Must be called at init time.
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            handleBackgroundDNSCheck(task: appRefreshTask)
        }
    }

    /// Schedule the next background wakeup (iOS decides when within ~15 min minimum).
    func scheduleBackgroundDNSCheck() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min minimum
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Called by iOS in the background. Re-checks DNS and reschedules itself.
    private func handleBackgroundDNSCheck(task: BGAppRefreshTask) {
        // Reschedule immediately so we keep running periodically
        scheduleBackgroundDNSCheck()

        let bgTask = Task {
            await syncService.recheckDNSOnForeground()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            bgTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
