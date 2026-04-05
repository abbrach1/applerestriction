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
    @Published var pendingWebsites: [String: String] = [:]
    @Published var pendingApps: [String: RecommendedApp] = [:]

    // Keep for legacy compatibility
    @Published var isPaired: Bool = false
    @Published var pendingCommands: [RemoteCommand] = []

    private lazy var dbRef: DatabaseReference = Database.database().reference()
    private var listenerHandles: [(DatabaseReference, DatabaseHandle)] = []
    private var connectedHandle: DatabaseHandle?

    // Still used by admin REST calls and manualSync fallback
    private let firebaseURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    private init() {}

    // MARK: - Real-time Listeners

    /// Start WebSocket listeners for all child-device data nodes.
    /// Call once after the child logs in and Screen Time is authorized.
    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stopListening()

        // .info/connected — true when WebSocket is connected to Firebase servers
        let connRef = Database.database().reference(withPath: ".info/connected")
        connectedHandle = connRef.observe(.value) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.isOnline = snapshot.value as? Bool ?? false
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
            try? await snapshot.ref.removeValue()   // delete after executing — no re-delivery
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
            try? await snapshot.ref.removeValue()   // delete after delivering
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
        let info: [String: Any] = [
            "email": email,
            "deviceName": DeviceInfo.current.name,
            "deviceModel": DeviceInfo.current.model,
            "deviceId": DeviceInfo.current.id,
            "isOnline": true,
            "lastSeen": ISO8601DateFormatter().string(from: Date())
        ]
        try? await dbRef.child("users/\(uid)/info").setValue(info)
        isPaired = true
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
    }

    // MARK: - Pending Item Removal

    func removePendingWebsite(pushKey: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try? await dbRef.child("users/\(uid)/pendingWebsites/\(pushKey)").removeValue()
        pendingWebsites.removeValue(forKey: pushKey)
    }

    func removePendingApp(pushKey: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try? await dbRef.child("users/\(uid)/pendingApps/\(pushKey)").removeValue()
        pendingApps.removeValue(forKey: pushKey)
    }

    // MARK: - Notification Permission

    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Private: Command Execution

    private func executeCommand(_ command: RemoteCommand) async {
        let mgr = ActiveScreenTimeSettingsManager.shared
        switch command.type {
        case .lockDevice:
            await MainActor.run { mgr.lockAllApps() }
        case .unlockAll:
            await MainActor.run { mgr.unlockAll() }
        case .updateBlockedApps, .updateTimeLimits, .updateDowntime,
             .updateWebsites, .refreshSettings:
            // Settings listener will already apply the latest config automatically.
            // Force an immediate fetch for instant response to the command.
            await manualSync()
        }
    }

    // MARK: - Private: Notification Delivery

    private func deliverLocalNotification(_ note: AdminNotification) async {
        let content = UNMutableNotificationContent()
        content.title = note.title.isEmpty ? "B-SAFE" : note.title
        content.body  = note.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Private: DNS Tamper Detection

    private func checkDNSTamper(config: ScreenTimeConfiguration, uid: String) async {
        guard config.forceDNS, config.dnsAlertOnRemoval || config.dnsAutoReapply else { return }
        #if !targetEnvironment(simulator)
        let isEnabled = await ContentBlockerService.shared.isDNSEnabled()
        guard !isEnabled else { return }

        if config.dnsAlertOnRemoval {
            let alert = TamperAlert(type: "dns_removed",
                                   message: "DNS filter profile was removed from the device.",
                                   timestamp: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            if let data = try? encoder.encode(alert),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? await dbRef.child("users/\(uid)/tamperAlerts").childByAutoId().setValue(dict)
            }
        }

        if config.dnsAutoReapply {
            await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID)
        }
        #endif
    }

    // MARK: - Legacy Polling Stubs (kept so call sites compile)

    /// Replaced by startListening(). Kept for source compatibility.
    func startPolling() { startListening() }
    func stopPolling()  { stopListening()  }
    func startNetworkMonitor() {}   // replaced by .info/connected listener
}
