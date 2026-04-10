import Foundation
import Combine
import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseDatabase

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
                self?.checkScheduledRelock()
            }
        }
    }

    #if !targetEnvironment(simulator)
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
        guard !isEnabled else {
            // DNS is healthy — clear any stale tamper alerts
            cancelDNSTamperAlerts()
            await MainActor.run { self.dnsProtectionMissing = false }
            return
        }

        // Attempt reapply — iOS may require user consent via a system dialog,
        // so we verify afterwards whether it actually took effect.
        if settings.dnsAutoReapply {
            await ContentBlockerService.shared.enableForcedDNS(profileID: settings.nextDNSProfileID)
        }

        // Check whether reapply actually succeeded
        let nowEnabled = await ContentBlockerService.shared.isDNSEnabled()

        // Alert admin with accurate status
        if settings.dnsAlertOnRemoval {
            let message = nowEnabled
                ? "DNS filter was removed and has been automatically restored."
                : "DNS filter was removed. Automatic restore failed — the child may have declined the prompt. Manual action required."
            let alert = TamperAlert(type: "dns_removed", message: message, timestamp: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            if let d = try? encoder.encode(alert),
               let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                _ = try? await dbRef.child("users/\(uid)/tamperAlerts").childByAutoId().setValue(dict)
            }
            let subject = nowEnabled ? "B-SAFE: DNS Protection Restored" : "B-SAFE: DNS Protection Removed"
            await sendEmailAlert(subject: subject, body: "Device: \(UIDevice.current.name)\n\(message)")
        }

        if !nowEnabled {
            scheduleDNSTamperAlerts()
            await MainActor.run { self.dnsProtectionMissing = true }
        } else {
            cancelDNSTamperAlerts()
            await MainActor.run { self.dnsProtectionMissing = false }
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
        await sendFCMToAdmin(
            title: "🔓 Unlock Request",
            body: "\(name)\(reason.isEmpty ? " is requesting an unlock" : ": \(reason)")"
        )
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
        await sendFCMToAdmin(
            title: "🌐 Website Request",
            body: "\(name) wants access to \(clean)\(reason.isEmpty ? "" : " — \(reason)")"
        )
    }

    func cancelWebsiteRequest(key: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        _ = try? await dbRef.child("users/\(uid)/websiteRequests/\(key)").removeValue()
        pendingWebsiteRequests.removeAll { $0.key == key }
    }

    // MARK: - FCM Push to Admin

    /// Sends a push notification to the admin device via FCM Legacy HTTP API.
    /// Admin must configure their FCM server key in the admin dashboard settings.
    /// Requires the admin device to have B-SAFE installed with notifications enabled.
    private func sendFCMToAdmin(title: String, body: String) async {
        let tokenSnap = try? await dbRef.child("adminConfig/fcmToken").getData()
        let keySnap   = try? await dbRef.child("adminConfig/fcmServerKey").getData()
        guard let token = tokenSnap?.value as? String, !token.isEmpty,
              let serverKey = keySnap?.value as? String, !serverKey.isEmpty else { return }
        guard let url = URL(string: "https://fcm.googleapis.com/fcm/send") else { return }
        let payload: [String: Any] = [
            "to": token,
            "notification": ["title": title, "body": body, "sound": "default"],
            "priority": "high"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("key=\(serverKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try? await URLSession.shared.data(for: req)
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
        guard config.forceDNS, config.dnsAlertOnRemoval || config.dnsAutoReapply else { return }
        #if !targetEnvironment(simulator)
        let isEnabled = await ContentBlockerService.shared.isDNSEnabled()
        guard !isEnabled else {
            dnsProtectionMissing = false
            return
        }

        if config.dnsAutoReapply {
            await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID)
        }

        let nowEnabled = await ContentBlockerService.shared.isDNSEnabled()
        dnsProtectionMissing = !nowEnabled

        if config.dnsAlertOnRemoval {
            let message = nowEnabled
                ? "DNS filter was removed and has been automatically restored."
                : "DNS filter was removed. Automatic restore failed — child may have declined. Manual action required."
            let alert = TamperAlert(type: "dns_removed", message: message, timestamp: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            if let data = try? encoder.encode(alert),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                _ = try? await dbRef.child("users/\(uid)/tamperAlerts").childByAutoId().setValue(dict)
            }
            let subject = nowEnabled ? "B-SAFE: DNS Protection Restored" : "B-SAFE: DNS Protection Removed"
            await sendEmailAlert(subject: subject, body: "Device: \(UIDevice.current.name)\n\(message)")
        }

        if !nowEnabled {
            scheduleDNSTamperAlerts()
        } else {
            cancelDNSTamperAlerts()
        }
        #endif
    }

    // MARK: - DNS Tamper Notifications

    /// Fire an immediate critical alert plus follow-ups every 60 s (up to 5 total)
    /// so the child can't simply ignore the notification and walk away.
    /// Uses the criticalAlert entitlement when approved by Apple; falls back to
    /// timeSensitive (bypasses Focus modes) otherwise.
    private func scheduleDNSTamperAlerts() {
        let center = UNUserNotificationCenter.current()
        // Cancel any stale series first
        center.removePendingNotificationRequests(withIdentifiers:
            (0..<5).map { "bsafe.dns.tamper.\($0)" })

        for i in 0..<5 {
            let content = UNMutableNotificationContent()
            content.title = "⚠️ Internet Protection Disabled"
            content.body = i == 0
                ? "DNS protection was removed. Open B-SAFE now to restore it."
                : "DNS protection is still disabled. Open B-SAFE to restore protection."
            content.sound = .defaultCritical
            content.interruptionLevel = .critical
            content.badge = NSNumber(value: 1)

            let trigger = i == 0 ? nil : UNTimeIntervalNotificationTrigger(
                timeInterval: Double(i) * 60, repeats: false)
            let req = UNNotificationRequest(
                identifier: "bsafe.dns.tamper.\(i)",
                content: content,
                trigger: trigger)
            UNUserNotificationCenter.current().add(req) { _ in }
        }
    }

    /// Cancel all pending DNS tamper notifications (called when DNS is restored).
    func cancelDNSTamperAlerts() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:
            (0..<5).map { "bsafe.dns.tamper.\($0)" })
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:
            (0..<5).map { "bsafe.dns.tamper.\($0)" })
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
