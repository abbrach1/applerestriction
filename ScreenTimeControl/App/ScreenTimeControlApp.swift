import SwiftUI
import FirebaseCore
import FirebaseDatabase
import BackgroundTasks
import UserNotifications

#if !targetEnvironment(simulator)
import FamilyControls
#endif

private let bgChildTaskID = "com.abbrachfeld.screentimecontrolabbrach.dnscheck"
private let bgAdminTaskID = "com.abbrachfeld.screentimecontrolabbrach.adminpoll"

// Allows local notifications to appear even when the app is in the foreground,
// and handles notification taps to open the right screen.
private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Clear badge when notification is tapped
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        completionHandler()
    }
}

private let notificationDelegate = NotificationDelegate()

@main
struct ScreenTimeControlApp: App {
    @StateObject private var auth = FirebaseAuthService.shared
    @StateObject private var authManager = ActiveAuthorizationManager.shared
    @StateObject private var settingsManager = ActiveScreenTimeSettingsManager.shared
    @StateObject private var syncService = RemoteSyncService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        Database.database().isPersistenceEnabled = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        registerBackgroundTasks()
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
                    .task { scheduleAdminPoll() }
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
                    .environmentObject(authManager)
                    .task {
                        syncService.requestNotificationPermission()
                        if let user = auth.currentUser {
                            await syncService.registerDevice(uid: user.uid, email: user.email, idToken: "")
                        }
                        syncService.startListening()
                        scheduleChildSync()
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                authManager.checkAuthorization()
            }
        }
    }

    // MARK: - Background Task Registration

    private func registerBackgroundTasks() {
        // Child: DNS recheck + full sync to pick up admin commands
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgChildTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            handleChildSyncTask(task: refreshTask)
        }
        // Admin: poll Firebase for pending requests, fire local notifications
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgAdminTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            handleAdminPollTask(task: refreshTask)
        }
    }

    // MARK: - Child Background Sync

    func scheduleChildSync() {
        let req = BGAppRefreshTaskRequest(identifier: bgChildTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) // 10 min
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleChildSyncTask(task: BGAppRefreshTask) {
        scheduleChildSync() // reschedule immediately

        let work = Task {
            // Re-check DNS profile and run a full sync to pick up any admin commands
            await syncService.recheckDNSOnForeground()
            await syncService.manualSync()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }

    // MARK: - Admin Background Poll

    func scheduleAdminPoll() {
        let req = BGAppRefreshTaskRequest(identifier: bgAdminTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) // 10 min
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleAdminPollTask(task: BGAppRefreshTask) {
        scheduleAdminPoll() // reschedule immediately

        let work = Task {
            await pollAdminRequests()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }

    /// Fetch all users' pending requests from Firebase and fire local notifications.
    private func pollAdminRequests() async {
        let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"
        guard let token = await FirebaseAuthService.shared.freshToken(),
              let url = URL(string: "\(dbURL)/users.json?auth=\(token)&shallow=false") else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let usersDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var unlockCount = 0
        var websiteCount = 0
        var unlockNames: [String] = []

        for (_, userVal) in usersDict {
            guard let userNode = userVal as? [String: Any] else { continue }
            let info = userNode["info"] as? [String: Any]
            let name = info?["displayName"] as? String ?? info?["email"] as? String ?? "A device"

            if let requests = userNode["unlockRequests"] as? [String: Any] {
                unlockCount += requests.count
                if requests.count > 0 { unlockNames.append(name) }
            }
            if let requests = userNode["websiteRequests"] as? [String: Any] {
                websiteCount += requests.count
            }
        }

        if unlockCount == 0 && websiteCount == 0 { return }

        // Don't re-notify for the same count — track last known counts
        let lastUnlock = UserDefaults.standard.integer(forKey: "bsafe.lastNotifiedUnlock")
        let lastWebsite = UserDefaults.standard.integer(forKey: "bsafe.lastNotifiedWebsite")
        guard unlockCount > lastUnlock || websiteCount > lastWebsite else { return }

        UserDefaults.standard.set(unlockCount, forKey: "bsafe.lastNotifiedUnlock")
        UserDefaults.standard.set(websiteCount, forKey: "bsafe.lastNotifiedWebsite")

        var parts: [String] = []
        if unlockCount > 0 {
            let names = unlockNames.prefix(2).joined(separator: ", ")
            parts.append("\(unlockCount) unlock request\(unlockCount == 1 ? "" : "s") from \(names)")
        }
        if websiteCount > 0 {
            parts.append("\(websiteCount) website request\(websiteCount == 1 ? "" : "s")")
        }

        let content = UNMutableNotificationContent()
        content.title = "B-SAFE — Action Required"
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        content.badge = NSNumber(value: unlockCount + websiteCount)

        let req = UNNotificationRequest(
            identifier: "bsafe.admin.pending.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // deliver immediately
        )
        _ = try? await UNUserNotificationCenter.current().add(req)
    }
}
