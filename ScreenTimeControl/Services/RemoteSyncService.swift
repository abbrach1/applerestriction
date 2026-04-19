import Foundation
import Combine
import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseDatabase

#if !targetEnvironment(simulator)
import SafariServices
#endif

/// Syncs Screen Time settings with Firebase Realtime Database.
///
/// Uses the Firebase Database SDK's WebSocket listeners instead of REST polling:
/// - One persistent WebSocket connection (vs 5 REST requests every 30s)
/// - Changes pushed from server instantly (vs up to 30s delay)
/// - .info/connected node tracks connection state (replaces NWPathMonitor)
/// - Offline persistence caches data so restrictions survive network drops
@MainActor
class RemoteSyncService: ObservableObject {
    static let shared = RemoteSyncService()

    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    @Published var isOnline: Bool = true
    @Published var dnsProtectionMissing: Bool = false
    @Published var webFilterProtectionMissing: Bool = false
    /// Epoch seconds when the current captive-portal bypass window ends.
    /// 0 means no window is open. The child-side banner keys off this.
    @Published var captiveBypassUntil: TimeInterval = 0
    private var captiveBypassTimer: Timer?
    @Published var pendingWebsites: [String: String] = [:]
    @Published var pendingApps: [String: RecommendedApp] = [:]
    @Published var displayName: String = ""
    @Published var pendingUnlockRequest: (key: String, request: UnlockRequest)? = nil
    @Published var pendingWebsiteRequests: [(key: String, request: WebsiteRequest)] = []

    // Keep for legacy compatibility
    @Published var isPaired: Bool = false
    @Published var pendingCommands: [RemoteCommand] = []

    private lazy var dbRef: DatabaseReference = Database.database().reference()
    private var listenerHandles: [(DatabaseReference, DatabaseHandle)] = []
    private var connectedHandle: DatabaseHandle?

    // Still used by admin REST calls and manualSync fallback
    private let firebaseURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    private init() {
        // Re-check DNS profile whenever app returns to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.recheckDNSOnForeground()
                await self?.recheckWebFilterOnForeground()
                self?.checkScheduledRelock()
            }
        }
    }

    #if !targetEnvironment(simulator)
    /// Unified DNS-tamper check. Called on foreground, BGAppRefreshTask, and
    /// whenever Firebase settings change. Re-schedules the child-facing 10-second
    /// notification queue whenever DNS is off, and (at most once per hour) writes
    /// a fresh TamperAlert + email + FCM push so the admin keeps getting notified
    /// for as long as the child leaves DNS disabled.
    ///
    /// Restoration is intentionally not attempted from inside the app — the child
    /// must go to Settings manually so the removal password set by the admin
    /// stays meaningful.
    func recheckDNSOnForeground() async {
        guard let uid = Auth.auth().currentUser?.uid,
              let snapshot = try? await Database.database()
                .reference(withPath: "users/\(uid)/settings")
                .getData(),
              let config = snapshot.value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: config),
              let settings = try? JSONDecoder().decode(ScreenTimeConfiguration.self, from: data),
              settings.forceDNS else { return }

        let isEnabled = await ContentBlockerService.shared.isDNSEnabled()
        if isEnabled {
            cancelDNSTamperAlerts()
            clearAdminAlertMark(type: "dns_removed")
            await MainActor.run { self.dnsProtectionMissing = false }
            return
        }

        // DNS is off — keep the 10-second user-facing notification queue primed
        // and, if enough time has passed, re-alert the admin.
        scheduleDNSTamperAlerts()
        await MainActor.run { self.dnsProtectionMissing = true }

        if settings.dnsAlertOnRemoval, shouldResendAdminAlert(type: "dns_removed") {
            let message = "DNS filter has been removed from this device. The child must restore it manually: Settings → General → VPN & Device Management → B-SAFE DNS → Install."
            await sendAdminTamperAlert(uid: uid,
                                       type: "dns_removed",
                                       subject: "B-SAFE: DNS Protection Removed",
                                       message: message)
        }
    }
    #else
    func recheckDNSOnForeground() async {}
    #endif

    // MARK: - Real-time Listeners

    /// Start WebSocket listeners for all child-device data nodes.
    /// Call once after the child logs in and Screen Time is authorized.
    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stopListening()

        // .info/connected — true when WebSocket is connected to Firebase servers.
        // Uses the standard Firebase presence pattern: on connect, mark online and
        // queue an onDisconnect write so the server flips isOnline=false automatically
        // when the WebSocket drops (app background, killed, no internet, etc).
        let connRef = Database.database().reference(withPath: ".info/connected")
        let infoRef = dbRef.child("users/\(uid)/info")

        connectedHandle = connRef.observe(.value) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                let connected = snapshot.value as? Bool ?? false
                self?.isOnline = connected
                if connected {
                    // Re-assert online status and (re-)queue disconnect handler.
                    // Must re-queue each time we reconnect because onDisconnect is
                    // consumed once by the server when the connection drops.
                    infoRef.child("isOnline").setValue(true)
                    infoRef.onDisconnectUpdateChildValues([
                        "isOnline": false,
                        "lastSeen": ServerValue.timestamp()
                    ])
                }
            }
        }

        // Fetch admin alert config once so child device can send emails
        // independently of the admin app being open.
        Task {
            let adminRef = Database.database().reference(withPath: "adminConfig")
            if let snap = try? await adminRef.getData(),
               let dict = snap.value as? [String: Any] {
                if let email = dict["alertEmail"] as? String, !email.isEmpty {
                    UserDefaults.standard.set(email, forKey: "bsafe.alertEmail")
                }
                if let key = dict["sendGridApiKey"] as? String, !key.isEmpty {
                    UserDefaults.standard.set(key, forKey: "bsafe.sendGridApiKey")
                }
            }
        }

        let userRef = dbRef.child("users/\(uid)")

        // Settings — fires immediately with current value, then on every change
        observe(userRef.child("settings")) { [weak self] snapshot in
            guard let self else { return }
            guard let dict = snapshot.value as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let config = try? decoder.decode(ScreenTimeConfiguration.self, from: data) else { return }
            await MainActor.run {
                ActiveScreenTimeSettingsManager.shared.applyRemoteConfiguration(config)
                self.lastSyncDate = Date()
                self.syncError = nil
            }
            await self.checkDNSTamper(config: config, uid: uid)
            await self.checkWebFilterTamper(config: config, uid: uid)
            await MainActor.run { self.syncCaptiveBypassState(config) }
        }

        // Commands — childAdded fires once per new command, not for existing ones
        observeChildAdded(userRef.child("commands")) { snapshot in
            guard let dict = snapshot.value as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let cmd = try? decoder.decode(RemoteCommand.self, from: data),
                  !cmd.executed else { return }
            await self.executeCommand(cmd)
            _ = try? await snapshot.ref.removeValue()   // delete after executing — no re-delivery
        }

        // Pending websites
        observe(userRef.child("pendingWebsites")) { [weak self] snapshot in
            await MainActor.run {
                self?.pendingWebsites = snapshot.value as? [String: String] ?? [:]
            }
        }

        // Pending apps
        observe(userRef.child("pendingApps")) { [weak self] snapshot in
            guard let self else { return }
            guard let dict = snapshot.value as? [String: Any] else {
                await MainActor.run { self.pendingApps = [:] }
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var result: [String: RecommendedApp] = [:]
            for (key, val) in dict {
                if let d = try? JSONSerialization.data(withJSONObject: val),
                   let app = try? decoder.decode(RecommendedApp.self, from: d) {
                    result[key] = app
                }
            }
            await MainActor.run { self.pendingApps = result }
        }

        // Notifications — childAdded fires once per new notification
        observeChildAdded(userRef.child("notifications")) { snapshot in
            guard let dict = snapshot.value as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let note = try? decoder.decode(AdminNotification.self, from: data) else { return }
            await self.deliverLocalNotification(note)
            _ = try? await snapshot.ref.removeValue()   // delete after delivering
        }

        // Unlock requests — watch so child sees when admin approves/denies
        observe(userRef.child("unlockRequests")) { [weak self] snapshot in
            guard let self else { return }
            if let dict = snapshot.value as? [String: Any],
               let (key, val) = dict.first,
               let data = try? JSONSerialization.data(withJSONObject: val) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                let req = try? decoder.decode(UnlockRequest.self, from: data)
                await MainActor.run { self.pendingUnlockRequest = req.map { (key, $0) } }
            } else {
                await MainActor.run { self.pendingUnlockRequest = nil }
            }
        }

        // Website requests — show child their pending requests
        observe(userRef.child("websiteRequests")) { [weak self] snapshot in
            guard let self else { return }
            guard let dict = snapshot.value as? [String: Any] else {
                await MainActor.run { self.pendingWebsiteRequests = [] }
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var result: [(key: String, request: WebsiteRequest)] = []
            for (key, val) in dict {
                if let data = try? JSONSerialization.data(withJSONObject: val),
                   let req = try? decoder.decode(WebsiteRequest.self, from: data) {
                    result.append((key, req))
                }
            }
            let sorted = result.sorted { $0.request.timestamp > $1.request.timestamp }
            await MainActor.run { self.pendingWebsiteRequests = sorted }
        }
    }

    func stopListening() {
        for (ref, handle) in listenerHandles {
            ref.removeObserver(withHandle: handle)
        }
        listenerHandles = []
        if let h = connectedHandle {
            Database.database().reference(withPath: ".info/connected").removeObserver(withHandle: h)
            connectedHandle = nil
        }
        // If the user explicitly signs out, immediately mark offline and cancel
        // the server-side onDisconnect (which would otherwise fire redundantly).
        if let uid = Auth.auth().currentUser?.uid {
            let infoRef = dbRef.child("users/\(uid)/info")
            infoRef.child("isOnline").setValue(false)
            infoRef.child("lastSeen").setValue(ISO8601DateFormatter().string(from: Date()))
            infoRef.cancelDisconnectOperations()
        }
    }

    // MARK: - Listener Helpers

    /// `.value` observer — fires with full snapshot on attach and on every change.
    private func observe(_ ref: DatabaseReference,
                         handler: @escaping (DataSnapshot) async -> Void) {
        let handle = ref.observe(.value) { snapshot in
            Task { await handler(snapshot) }
        }
        listenerHandles.append((ref, handle))
    }

    /// `.childAdded` observer — fires once per existing child on attach,
    /// then once for each new child added afterwards.
    private func observeChildAdded(_ ref: DatabaseReference,
                                   handler: @escaping (DataSnapshot) async -> Void) {
        let handle = ref.observe(.childAdded) { snapshot in
            Task { await handler(snapshot) }
        }
        listenerHandles.append((ref, handle))
    }

    // MARK: - Device Registration

    func registerDevice(uid: String, email: String, idToken: String) async {
        // Load existing displayName first so we don't overwrite it
        let existing = try? await dbRef.child("users/\(uid)/info/displayName").getData()
        let savedName = existing?.value as? String ?? ""
        if !savedName.isEmpty { displayName = savedName }

        // Battery
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryStateStr: String
        switch UIDevice.current.batteryState {
        case .charging:  batteryStateStr = "charging"
        case .full:      batteryStateStr = "full"
        case .unplugged: batteryStateStr = "unplugged"
        default:         batteryStateStr = "unknown"
        }

        // Storage
        var storageTotal: Int64 = 0
        var storageFree:  Int64 = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            storageTotal = attrs[.systemSize]     as? Int64 ?? 0
            storageFree  = attrs[.systemFreeSize] as? Int64 ?? 0
        }

        var info: [String: Any] = [
            "email":         email,
            "displayName":   savedName,
            "deviceName":    DeviceInfo.current.name,
            "deviceModel":   DeviceInfo.current.model,
            "deviceId":      DeviceInfo.current.id,
            "systemVersion": UIDevice.current.systemVersion,
            "isOnline":      true,
            "lastSeen":      ISO8601DateFormatter().string(from: Date()),
            "storageTotal":  storageTotal,
            "storageFree":   storageFree,
        ]
        if batteryLevel >= 0 {
            info["batteryLevel"] = Double(batteryLevel)
            info["batteryState"] = batteryStateStr
        }

        _ = try? await dbRef.child("users/\(uid)/info").setValue(info)
        isPaired = true
    }

    func setDisplayName(_ name: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        displayName = name
        _ = try? await dbRef.child("users/\(uid)/info/displayName").setValue(name)
    }

    // MARK: - Unlock Requests

    func sendUnlockRequest(reason: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let req = UnlockRequest(
            reason: reason,
            timestamp: Date(),
            deviceName: DeviceInfo.current.name
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(req),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        _ = try? await dbRef.child("users/\(uid)/unlockRequests").childByAutoId().setValue(dict)
        let name = displayName.isEmpty ? DeviceInfo.current.name : displayName
        let body = "\(name)\(reason.isEmpty ? " is requesting an unlock" : ": \(reason)")"
        await sendFCMToAdmin(title: "🔓 Unlock Request", body: body)
        await sendEmailAlert(subject: "B-SAFE: Unlock Request", body: body)
    }

    func cancelUnlockRequest() async {
        guard let uid = Auth.auth().currentUser?.uid,
              let key = pendingUnlockRequest?.key else { return }
        _ = try? await dbRef.child("users/\(uid)/unlockRequests/\(key)").removeValue()
        pendingUnlockRequest = nil
    }

    // MARK: - Website Requests

    func sendWebsiteRequest(domain: String, reason: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let clean = domain
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: "/").first ?? domain
        var req = WebsiteRequest()
        req.domain = clean
        req.reason = reason
        req.timestamp = Date()
        req.deviceName = DeviceInfo.current.name
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(req),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        _ = try? await dbRef.child("users/\(uid)/websiteRequests").childByAutoId().setValue(dict)
        let name = displayName.isEmpty ? DeviceInfo.current.name : displayName
        let body = "\(name) wants access to \(clean)\(reason.isEmpty ? "" : " — \(reason)")"
        await sendFCMToAdmin(title: "🌐 Website Request", body: body)
        await sendEmailAlert(subject: "B-SAFE: Website Request", body: body)
    }

    func cancelWebsiteRequest(key: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        _ = try? await dbRef.child("users/\(uid)/websiteRequests/\(key)").removeValue()
        pendingWebsiteRequests.removeAll { $0.key == key }
    }

    // MARK: - FCM Push to Admin (v1 API)

    /// Sends a push notification to the admin device via FCM HTTP v1 API.
    /// Credentials come from FCMServiceAccount.plist bundled in the app target.
    private func sendFCMToAdmin(title: String, body: String) async {
        guard let snap = try? await dbRef.child("adminConfig/fcmToken").getData(),
              let token = snap.value as? String, !token.isEmpty else { return }
        await FCMv1Service.shared.send(to: token, title: title, body: body)
    }

    // MARK: - Manual Sync (refresh button)

    /// Forces a fresh fetch from the server bypassing the local cache.
    func manualSync() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let snapshot = try await dbRef.child("users/\(uid)/settings").getData()
            guard let dict = snapshot.value as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            if let config = try? decoder.decode(ScreenTimeConfiguration.self, from: data) {
                ActiveScreenTimeSettingsManager.shared.applyRemoteConfiguration(config)
                lastSyncDate = Date()
                syncError = nil
            }
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
        }
        await deliverPendingNotifications(uid: uid)
    }

    /// Reads /users/{uid}/notifications, fires local UNNotifications, then deletes each one.
    private func deliverPendingNotifications(uid: String) async {
        let snap = try? await dbRef.child("users/\(uid)/notifications").getData()
        guard let dict = snap?.value as? [String: Any] else { return }
        for (key, val) in dict {
            guard let entry = val as? [String: Any],
                  let title = entry["title"] as? String,
                  let body = entry["body"] as? String else { continue }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "bsafe.child.notify.\(key)",
                content: content,
                trigger: nil)
            _ = try? await UNUserNotificationCenter.current().add(req)
            _ = try? await dbRef.child("users/\(uid)/notifications/\(key)").removeValue()
        }
    }

    // MARK: - Pending Item Removal

    func removePendingWebsite(pushKey: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        _ = try? await dbRef.child("users/\(uid)/pendingWebsites/\(pushKey)").removeValue()
        pendingWebsites.removeValue(forKey: pushKey)
    }

    func removePendingApp(pushKey: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        _ = try? await dbRef.child("users/\(uid)/pendingApps/\(pushKey)").removeValue()
        pendingApps.removeValue(forKey: pushKey)
    }

    // MARK: - Notification Permission

    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { _, _ in }
    }

    // MARK: - Private: Command Execution

    private func executeCommand(_ command: RemoteCommand) async {
        let mgr = ActiveScreenTimeSettingsManager.shared
        switch command.type {
        case .lockDevice:
            await MainActor.run { mgr.lockAllApps() }
            // Clear any scheduled re-lock — device is already locked
            UserDefaults.standard.removeObject(forKey: "bsafe.relockAt")
        case .unlockAll:
            await MainActor.run { mgr.unlockAll() }
            // Schedule timed re-lock if admin sent a duration in the payload
            if let durStr = command.payload["durationMinutes"],
               let minutes = Int(durStr), minutes > 0 {
                let relockAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
                UserDefaults.standard.set(relockAt.timeIntervalSince1970, forKey: "bsafe.relockAt")
                scheduleRelockTimer(after: TimeInterval(minutes * 60))
            } else {
                UserDefaults.standard.removeObject(forKey: "bsafe.relockAt")
            }
        case .updateBlockedApps, .updateTimeLimits, .updateDowntime,
             .updateWebsites, .refreshSettings:
            await manualSync()
        }
    }

    func checkScheduledRelock() {
        guard let ts = UserDefaults.standard.value(forKey: "bsafe.relockAt") as? TimeInterval else { return }
        let relockAt = Date(timeIntervalSince1970: ts)
        if Date() >= relockAt {
            ActiveScreenTimeSettingsManager.shared.lockAllApps()
            UserDefaults.standard.removeObject(forKey: "bsafe.relockAt")
        } else {
            scheduleRelockTimer(after: relockAt.timeIntervalSinceNow)
        }
    }

    private func scheduleRelockTimer(after interval: TimeInterval) {
        Task {
            _ = try? await Task.sleep(nanoseconds: UInt64(max(0, interval)) * 1_000_000_000)
            if let ts = UserDefaults.standard.value(forKey: "bsafe.relockAt") as? TimeInterval,
               Date() >= Date(timeIntervalSince1970: ts) {
                await MainActor.run { ActiveScreenTimeSettingsManager.shared.lockAllApps() }
                UserDefaults.standard.removeObject(forKey: "bsafe.relockAt")
            }
        }
    }

    // MARK: - Emergency Bypass Code

    func redeemBypassCode(_ code: String) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        let snapshot = try? await dbRef.child("users/\(uid)/emergencyBypass").getData()
        guard let dict = snapshot?.value as? [String: Any] else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for (_, val) in dict {
            guard let data = try? JSONSerialization.data(withJSONObject: val),
                  var bypass = try? decoder.decode(EmergencyBypassCode.self, from: data),
                  bypass.code == code, !bypass.used else { continue }
            // Valid code — mark used, unlock, schedule re-lock
            bypass.used = true
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            if let updData = try? encoder.encode(bypass),
               let updDict = try? JSONSerialization.jsonObject(with: updData) as? [String: Any] {
                // Delete the bypass code so it can't be reused
                _ = try? await dbRef.child("users/\(uid)/emergencyBypass").setValue(nil)
                _ = updDict
            }
            let minutes = bypass.durationMinutes
            await MainActor.run { ActiveScreenTimeSettingsManager.shared.unlockAll() }
            if minutes > 0 {
                let relockAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
                UserDefaults.standard.set(relockAt.timeIntervalSince1970, forKey: "bsafe.relockAt")
                scheduleRelockTimer(after: TimeInterval(minutes * 60))
            }
            return true
        }
        return false
    }

    // MARK: - Private: Notification Delivery

    private func deliverLocalNotification(_ note: AdminNotification) async {
        let content = UNMutableNotificationContent()
        content.title = note.title.isEmpty ? "B-SAFE" : note.title
        content.body  = note.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
        _ = try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Private: DNS Tamper Detection

    private func checkDNSTamper(config: ScreenTimeConfiguration, uid: String) async {
        guard config.forceDNS, config.dnsAlertOnRemoval else { return }
        #if !targetEnvironment(simulator)
        let isEnabled = await ContentBlockerService.shared.isDNSEnabled()
        if isEnabled {
            dnsProtectionMissing = false
            cancelDNSTamperAlerts()
            clearAdminAlertMark(type: "dns_removed")
            return
        }

        dnsProtectionMissing = true
        scheduleDNSTamperAlerts()

        if shouldResendAdminAlert(type: "dns_removed") {
            let message = "DNS filter has been removed from this device. The child must restore it manually: Settings → General → VPN & Device Management → B-SAFE DNS → Install."
            await sendAdminTamperAlert(uid: uid,
                                       type: "dns_removed",
                                       subject: "B-SAFE: DNS Protection Removed",
                                       message: message)
        }
        #endif
    }

    // MARK: - Tamper Notification Queue (shared)

    // iOS caps pending local notifications at 64 per app. We leave one slot
    // free for the admin-push pipeline and fill the remaining 63 with
    // 10-second-spaced reminders. The queue drains in ~10.5 minutes; the
    // BGAppRefreshTask and every foreground refill it as soon as iOS gives
    // the app CPU time, which is the best we can do without a server-side
    // push pipeline.
    private static let tamperSlotCount = 63
    private static let tamperSlotInterval: TimeInterval = 10

    private func scheduleTamperAlerts(prefix: String, title: String, body: String, critical: Bool) {
        let center = UNUserNotificationCenter.current()
        let ids = (0..<Self.tamperSlotCount).map { "\(prefix).\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)

        for i in 0..<Self.tamperSlotCount {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = body
            content.sound = critical ? .defaultCritical : .default
            content.interruptionLevel = critical ? .critical : .timeSensitive
            content.badge = NSNumber(value: 1)

            // First fires in 1 s, then every 10 s (1, 11, 21, 31, …).
            let offset = max(1, Double(i) * Self.tamperSlotInterval)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: offset, repeats: false)
            let req = UNNotificationRequest(
                identifier: "\(prefix).\(i)",
                content: content,
                trigger: trigger)
            center.add(req) { _ in }
        }
    }

    private func cancelTamperAlerts(prefix: String) {
        let ids = (0..<Self.tamperSlotCount).map { "\(prefix).\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Keep the DNS-tamper queue full (63 notifications at 10 s intervals).
    private func scheduleDNSTamperAlerts() {
        scheduleTamperAlerts(
            prefix: "bsafe.dns.tamper",
            title: "⚠️ Internet Protection Disabled",
            body:  "DNS protection is off. Restore it in Settings → General → VPN & Device Management → B-SAFE DNS → Install.",
            critical: true)
    }

    /// Cancel all pending DNS tamper notifications (called when DNS is restored).
    func cancelDNSTamperAlerts() { cancelTamperAlerts(prefix: "bsafe.dns.tamper") }

    // MARK: - Web Filter Tamper Detection

    /// Re-check whether the Safari Content Blocker + NEFilter are still enforcing
    /// the website list. Called on foreground, on every settings update, and from
    /// the background-refresh task.
    func recheckWebFilterOnForeground() async {
        #if !targetEnvironment(simulator)
        guard let uid = Auth.auth().currentUser?.uid,
              let snapshot = try? await Database.database()
                .reference(withPath: "users/\(uid)/settings")
                .getData(),
              let dict = snapshot.value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let settings = try? JSONDecoder().decode(ScreenTimeConfiguration.self, from: data) else {
            return
        }
        await checkWebFilterTamper(config: settings, uid: uid)
        #endif
    }

    private func checkWebFilterTamper(config: ScreenTimeConfiguration, uid: String) async {
        #if !targetEnvironment(simulator)
        let hasRestrictions = config.websiteFilterMode == .whitelist || !config.blockedWebsites.isEmpty
        guard hasRestrictions else {
            webFilterProtectionMissing = false
            cancelWebFilterTamperAlerts()
            clearAdminAlertMark(type: "web_filter_disabled")
            return
        }

        let blockerID = "com.abbrachfeld.screentimecontrolabbrach.BSAFEContentBlocker"
        let blockerState = try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: blockerID)
        let safariOn = blockerState?.isEnabled ?? false
        let filterOn = await ContentFilterService.shared.isEnabled()

        if safariOn && filterOn {
            webFilterProtectionMissing = false
            cancelWebFilterTamperAlerts()
            clearAdminAlertMark(type: "web_filter_disabled")
            return
        }

        webFilterProtectionMissing = true

        let message: String
        let bothOff = !safariOn && !filterOn
        if bothOff {
            message = "Website filter completely disabled. Both the Safari Content Blocker and the Network Filter were turned off — the child can browse without restrictions."
        } else if !filterOn {
            message = "Network Filter was turned off. Safari is still filtered, but other apps and browsers can bypass the website list."
        } else {
            message = "Safari Content Blocker was turned off. The Network Filter is still enforcing the website list system-wide, but Safari-specific rules are not active."
        }

        scheduleWebFilterTamperAlerts(bothOff: bothOff)

        if shouldResendAdminAlert(type: "web_filter_disabled") {
            await sendAdminTamperAlert(uid: uid,
                                       type: "web_filter_disabled",
                                       subject: "B-SAFE: Website Filter Disabled",
                                       message: message)
        }
        #endif
    }

    private func scheduleWebFilterTamperAlerts(bothOff: Bool) {
        scheduleTamperAlerts(
            prefix: "bsafe.webfilter.tamper",
            title: "⚠️ Website Filter Disabled",
            body: bothOff
                ? "Re-enable B-SAFE Content Blocker (Settings → Safari → Extensions) AND the Network Filter (Settings → General → VPN & Device Management → B-SAFE Content Filter)."
                : "A website filter component is off. Open the B-SAFE setup checklist to restore protection.",
            critical: false)
    }

    func cancelWebFilterTamperAlerts() { cancelTamperAlerts(prefix: "bsafe.webfilter.tamper") }

    // MARK: - Captive Portal Bypass

    /// Opens the captive-portal bypass window for `minutes` minutes. Writes
    /// the end-timestamp to Firebase so admin + every other device sees the
    /// same state, writes it to the App Group so NEFilter reads it on the
    /// very next flow, flips Safari Content Blocker to empty rules, and
    /// schedules a timer to restore normal filtering when the window expires.
    func openCaptiveBypass(minutes: Int) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        #if !targetEnvironment(simulator)
        let snap = try? await dbRef.child("users/\(uid)/settings").getData()
        guard let dict = snap?.value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var settings = try? JSONDecoder().decode(ScreenTimeConfiguration.self, from: data),
              settings.captiveBypassAllowed else {
            return
        }

        let duration = max(1, min(minutes, settings.captiveBypassMinutes > 0 ? settings.captiveBypassMinutes : 5))
        let until = Date().timeIntervalSince1970 + Double(duration * 60)
        settings.captiveBypassUntil = until
        captiveBypassUntil = until

        // Push the new config to the child's persisted state so a background
        // relaunch during the window still sees the bypass.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let out = try? encoder.encode(settings),
           let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
            _ = try? await dbRef.child("users/\(uid)/settings").setValue(json)
        }

        // Let NEFilter and Safari know immediately.
        ContentFilterService.shared.openCaptiveBypass(until: until)
        ContentBlockerService.shared.applyRules(for: settings)

        // Alert the admin — tamper-alert pipeline already handles Firebase +
        // email + FCM. Rate-limit key is distinct so the hourly-dedupe used
        // for tamper types doesn't swallow it.
        let message = "Captive-portal bypass opened for \(duration) minute\(duration == 1 ? "" : "s"). All website filtering is temporarily passing traffic so the child can log in to a captive WiFi network."
        await sendAdminCaptiveNotice(uid: uid, message: message)

        scheduleCaptiveBypassClose(at: until)
    }

    /// Closes the bypass window now — called by the auto-expire timer, the
    /// admin's "Close Now" button, and on app launch if we find the
    /// persisted window has already expired.
    func closeCaptiveBypass() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        captiveBypassUntil = 0
        captiveBypassTimer?.invalidate()
        captiveBypassTimer = nil

        #if !targetEnvironment(simulator)
        ContentFilterService.shared.closeCaptiveBypass()

        // Re-fetch the up-to-date settings and reapply them so the real
        // filter list is back in force.
        let snap = try? await dbRef.child("users/\(uid)/settings").getData()
        guard let dict = snap?.value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var settings = try? JSONDecoder().decode(ScreenTimeConfiguration.self, from: data) else {
            return
        }
        settings.captiveBypassUntil = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let out = try? encoder.encode(settings),
           let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
            _ = try? await dbRef.child("users/\(uid)/settings").setValue(json)
        }
        ContentBlockerService.shared.applyRules(for: settings)
        #endif
    }

    /// Called after we load settings from Firebase so the timer + the
    /// published `captiveBypassUntil` match the server's view. Handles the
    /// case where the admin opens a window, the child device is offline,
    /// then comes back online with the window still active.
    func syncCaptiveBypassState(_ config: ScreenTimeConfiguration) {
        let now = Date().timeIntervalSince1970
        if config.captiveBypassUntil > now {
            captiveBypassUntil = config.captiveBypassUntil
            scheduleCaptiveBypassClose(at: config.captiveBypassUntil)
        } else if captiveBypassUntil != 0 {
            // Either already expired or admin force-closed — clean up.
            Task { await closeCaptiveBypass() }
        }
    }

    private func scheduleCaptiveBypassClose(at until: TimeInterval) {
        captiveBypassTimer?.invalidate()
        let seconds = max(1, until - Date().timeIntervalSince1970)
        captiveBypassTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.closeCaptiveBypass() }
        }
    }

    private func sendAdminCaptiveNotice(uid: String, message: String) async {
        let device = UIDevice.current.name
        let subject = "B-SAFE: Captive WiFi Bypass Opened"
        let body = "Device: \(device)\n\(message)"

        let alert = TamperAlert(type: "captive_bypass_opened", message: message, timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let d = try? encoder.encode(alert),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            _ = try? await dbRef.child("users/\(uid)/tamperAlerts").childByAutoId().setValue(dict)
        }
        await sendEmailAlert(subject: subject, body: body)
        await sendFCMToAdmin(title: subject, body: body)
    }

    // MARK: - Admin Tamper Alert Dispatch

    /// Maximum frequency at which we re-notify the admin about an ongoing
    /// tamper condition. Set to 1 hour — if the child leaves DNS off for 12
    /// hours, the admin gets 12 emails + 12 FCM pushes + 12 Firebase alerts.
    private static let adminTamperResendInterval: TimeInterval = 3600

    private func shouldResendAdminAlert(type: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: "bsafe.tamper.lastAdminAlert.\(type)")
        return last == 0 || Date().timeIntervalSince1970 - last >= Self.adminTamperResendInterval
    }

    private func markAdminAlertSent(type: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: "bsafe.tamper.lastAdminAlert.\(type)")
    }

    private func clearAdminAlertMark(type: String) {
        UserDefaults.standard.removeObject(forKey: "bsafe.tamper.lastAdminAlert.\(type)")
    }

    /// Fire all three admin-facing channels for a tamper event: a Firebase
    /// TamperAlert row (dashboard banner), a SendGrid email, and an FCM push to
    /// the admin device. Rate-limited to once per hour per tamper type via
    /// `shouldResendAdminAlert`.
    private func sendAdminTamperAlert(uid: String, type: String, subject: String, message: String) async {
        let device = UIDevice.current.name
        let body = "Device: \(device)\n\(message)"

        // 1. Firebase TamperAlert — shows up in the admin dashboard banner.
        let alert = TamperAlert(type: type, message: message, timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let d = try? encoder.encode(alert),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            _ = try? await dbRef.child("users/\(uid)/tamperAlerts").childByAutoId().setValue(dict)
        }

        // 2. Email via SendGrid.
        await sendEmailAlert(subject: subject, body: body)

        // 3. Push notification to admin device via FCM HTTP v1 API.
        await sendFCMToAdmin(title: subject, body: body)

        markAdminAlertSent(type: type)
    }

    // MARK: - Email Alerts (SendGrid)

    /// Sends an email alert via SendGrid REST API.
    /// Admin enters their email + SendGrid API key in Notification Settings.
    private func sendEmailAlert(subject: String, body: String) async {
        let email = UserDefaults.standard.string(forKey: "bsafe.alertEmail") ?? ""
        let apiKey = UserDefaults.standard.string(forKey: "bsafe.sendGridApiKey") ?? ""
        guard !email.isEmpty, !apiKey.isEmpty else { return }
        let payload: [String: Any] = [
            "personalizations": [["to": [["email": email]]]],
            "from": ["email": "bsafe.dnslogs@gmail.com", "name": "B-SAFE"],
            "subject": subject,
            "content": [["type": "text/plain", "value": body]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://api.sendgrid.com/v3/mail/send") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Legacy Polling Stubs (kept so call sites compile)

    /// Replaced by startListening(). Kept for source compatibility.
    func startPolling() { startListening() }
    func stopPolling()  { stopListening()  }
    func startNetworkMonitor() {}   // replaced by .info/connected listener
}
