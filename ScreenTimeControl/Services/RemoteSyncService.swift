import Foundation
import Combine
import UIKit
import UserNotifications

/// Syncs Screen Time settings with Firebase Realtime Database for remote control.
///
/// SETUP:
/// 1. Go to https://console.firebase.google.com
/// 2. Create a project → Realtime Database → Start in test mode
/// 3. Copy your database URL (looks like: https://your-project-default-rtdb.firebaseio.com)
/// 4. Enter it in the app's Settings tab under "Firebase URL"
@MainActor
class RemoteSyncService: ObservableObject {
    static let shared = RemoteSyncService()

    @Published var isPaired: Bool = false
    @Published var pairingCode: String = ""
    @Published var connectedDevices: [DeviceInfo] = []
    @Published var pendingCommands: [RemoteCommand] = []
    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    @Published var pendingWebsites: [String: String] = [:]  // [pushKey: domain]

    /// Firebase Realtime Database URL
    private static let defaultFirebaseURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    var firebaseURL: String {
        get { UserDefaults.standard.string(forKey: "remote.firebaseURL") ?? Self.defaultFirebaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "remote.firebaseURL") }
    }

    private var deviceId: String { DeviceInfo.current.id }
    private var pollTimer: Timer?

    private init() {}

    // MARK: - Child Device Registration

    /// Call after login: registers this device under the user's UID in Firebase
    func registerDevice(uid: String, email: String, idToken: String) async {
        let info: [String: Any] = [
            "email": email,
            "deviceName": DeviceInfo.current.name,
            "deviceModel": DeviceInfo.current.model,
            "deviceId": deviceId,
            "isOnline": true,
            "lastSeen": ISO8601DateFormatter().string(from: Date())
        ]
        guard let url = URL(string: "\(firebaseURL)/users/\(uid)/info.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: info)
        _ = try? await URLSession.shared.data(for: req)
        isPaired = true
    }

    // MARK: - Pairing

    /// Child device: generate a 6-digit code and register this device on Firebase
    func generatePairingCode() async {
        let code = String(format: "%06d", Int.random(in: 100000...999999))
        pairingCode = code

        var info = DeviceInfo.current
        info.isOnline = true

        // Store device info under /pairing/{code} so parent can find it
        do {
            try await firebasePut(
                path: "pairing/\(code)",
                body: encodable(info)
            )
            // Also register under /devices/{id}
            try await firebasePut(
                path: "devices/\(deviceId)/info",
                body: encodable(info)
            )

            UserDefaults.standard.set(code, forKey: "remote.pairingCode")
            UserDefaults.standard.set(true, forKey: "remote.isPaired")
            isPaired = true
            syncError = nil
        } catch {
            syncError = "Registration failed: \(error.localizedDescription)"
        }
    }

    /// Parent device: look up a child device by its pairing code and link to it
    func pairWithDevice(code: String) async {
        do {
            let data = try await firebaseGet(path: "pairing/\(code)")
            let childDevice = try JSONDecoder().decode(DeviceInfo.self, from: data)

            connectedDevices.append(childDevice)
            isPaired = true

            // Persist connected devices list
            if let encoded = try? JSONEncoder().encode(connectedDevices) {
                UserDefaults.standard.set(encoded, forKey: "remote.connectedDevices")
            }
            UserDefaults.standard.set(true, forKey: "remote.isPaired")

            // Remove pairing code once used
            try? await firebaseDelete(path: "pairing/\(code)")

            syncError = nil
        } catch {
            syncError = "Pairing failed — check the code and try again"
        }
    }

    // MARK: - Settings Sync

    /// Push current settings to Firebase (called from parent after configuring restrictions)
    func pushSettings(_ config: ScreenTimeConfiguration) async {
        do {
            try await firebasePut(
                path: "devices/\(config.deviceId.isEmpty ? deviceId : config.deviceId)/settings",
                body: encodable(config)
            )
            lastSyncDate = Date()
            syncError = nil
        } catch {
            syncError = "Push failed: \(error.localizedDescription)"
        }
    }

    /// Pull settings from Firebase (called on child device)
    func pullSettings() async -> ScreenTimeConfiguration? {
        do {
            let data = try await firebaseGet(path: "devices/\(deviceId)/settings")
            let config = try JSONDecoder().decode(ScreenTimeConfiguration.self, from: data)
            lastSyncDate = Date()
            syncError = nil
            return config
        } catch {
            // null response means no settings yet — not an error
            return nil
        }
    }

    // MARK: - Remote Commands

    /// Parent → sends a command to a specific child device
    func sendCommand(_ command: RemoteCommand, toDevice targetDeviceId: String) async {
        do {
            // Firebase POST under /devices/{id}/commands/ creates a unique child key
            try await firebasePost(
                path: "devices/\(targetDeviceId)/commands",
                body: encodable(command)
            )
            syncError = nil
        } catch {
            syncError = "Command failed: \(error.localizedDescription)"
        }
    }

    /// Child → fetches all unexecuted commands from Firebase (UID-based path)
    func checkForCommands() async -> [RemoteCommand] {
        let authService = FirebaseAuthService.shared
        guard let user = authService.currentUser else { return [] }
        let token = await authService.freshToken() ?? user.idToken
        let path = "users/\(user.uid)/commands"
        do {
            let data = try await firebaseGet(path: path, idToken: token)
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var commands: [RemoteCommand] = []
            for (_, value) in dict {
                if let cmdData = try? JSONSerialization.data(withJSONObject: value),
                   let cmd = try? decoder.decode(RemoteCommand.self, from: cmdData),
                   !cmd.executed {
                    commands.append(cmd)
                }
            }
            pendingCommands = commands
            return commands
        } catch { return [] }
    }

    /// Child → marks a command as done by deleting it from Firebase
    func markCommandExecuted(_ commandId: String) async {
        let authService = FirebaseAuthService.shared
        guard let user = authService.currentUser else { return }
        let token = await authService.freshToken() ?? user.idToken
        let path = "users/\(user.uid)/commands"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let data = try? await firebaseGet(path: path, idToken: token),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (pushKey, value) in dict {
                if let cmdData = try? JSONSerialization.data(withJSONObject: value),
                   let cmd = try? decoder.decode(RemoteCommand.self, from: cmdData),
                   cmd.id == commandId {
                    try? await firebaseDelete(path: "\(path)/\(pushKey)", idToken: token)
                }
            }
        }
    }

    // MARK: - Polling

    /// Child device: start polling Firebase for new commands
    func startPolling(interval: TimeInterval = 10) {
        stopPolling()
        // Apply latest saved settings immediately, then keep polling for commands
        Task { await manualSync() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollAndExecute()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollAndExecute() async {
        let commands = await checkForCommands()
        for command in commands {
            await executeCommand(command)
        }
        guard let user = FirebaseAuthService.shared.currentUser else { return }
        let token = await FirebaseAuthService.shared.freshToken() ?? user.idToken
        async let configFetch = loadUserSettings(uid: user.uid, idToken: token)
        async let websitesFetch: Void = loadPendingWebsites()
        async let notifFetch: Void = deliverPendingNotifications(uid: user.uid, idToken: token)
        let (fetchedConfig, _, _) = await (configFetch, websitesFetch, notifFetch)
        if let config = fetchedConfig {
            ActiveScreenTimeSettingsManager.shared.applyRemoteConfiguration(config)
            await checkDNSTamper(config: config, uid: user.uid, idToken: token)
        }
        lastSyncDate = Date()
    }

    // MARK: - Notifications

    /// Request permission once at startup (child device only).
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Poll /users/uid/notifications, fire a local notification for each, then delete from Firebase.
    private func deliverPendingNotifications(uid: String, idToken: String) async {
        guard let url = URL(string: "\(firebaseURL)/users/\(uid)/notifications.json?auth=\(idToken)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        for (pushKey, value) in dict {
            guard let noteData = try? JSONSerialization.data(withJSONObject: value),
                  let note = try? decoder.decode(AdminNotification.self, from: noteData) else { continue }

            // Show local notification
            let content = UNMutableNotificationContent()
            content.title = note.title.isEmpty ? "B-SAFE" : note.title
            content.body  = note.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: note.id,
                content: content,
                trigger: nil  // deliver immediately
            )
            try? await UNUserNotificationCenter.current().add(request)

            // Delete from Firebase so it doesn't re-deliver
            try? await firebaseDelete(path: "users/\(uid)/notifications/\(pushKey)", idToken: idToken)
        }
    }

    func loadPendingWebsites() async {
        guard let user = FirebaseAuthService.shared.currentUser else { return }
        let token = await FirebaseAuthService.shared.freshToken() ?? user.idToken
        guard let url = URL(string: "\(firebaseURL)/users/\(user.uid)/pendingWebsites.json?auth=\(token)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            pendingWebsites = dict
        } else {
            pendingWebsites = [:]
        }
    }

    func removePendingWebsite(pushKey: String) async {
        guard let user = FirebaseAuthService.shared.currentUser else { return }
        let token = await FirebaseAuthService.shared.freshToken() ?? user.idToken
        try? await firebaseDelete(path: "users/\(user.uid)/pendingWebsites/\(pushKey)", idToken: token)
        pendingWebsites.removeValue(forKey: pushKey)
    }

    /// Manually poll and apply commands + latest settings. Called from ChildDeviceView refresh button.
    func manualSync() async {
        let commands = await checkForCommands()
        for command in commands {
            await executeCommand(command)
        }
        guard let user = FirebaseAuthService.shared.currentUser else { return }
        let token = await FirebaseAuthService.shared.freshToken() ?? user.idToken
        async let configFetch = loadUserSettings(uid: user.uid, idToken: token)
        async let websitesFetch: Void = loadPendingWebsites()
        async let notifFetch: Void = deliverPendingNotifications(uid: user.uid, idToken: token)
        let (fetchedConfig, _, _) = await (configFetch, websitesFetch, notifFetch)
        if let fetchedConfig {
            ActiveScreenTimeSettingsManager.shared.applyRemoteConfiguration(fetchedConfig)
        }
        lastSyncDate = Date()
    }

    /// Load the admin-saved ScreenTimeConfiguration for a user from Firebase
    func loadUserSettings(uid: String, idToken: String) async -> ScreenTimeConfiguration? {
        guard let url = URL(string: "\(firebaseURL)/users/\(uid)/settings.json?auth=\(idToken)") else { return nil }
        if let (data, _) = try? await URLSession.shared.data(from: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            if let config = try? decoder.decode(ScreenTimeConfiguration.self, from: data) {
                return config
            }
        }
        return nil
    }

    private func executeCommand(_ command: RemoteCommand) async {
        let settingsManager = ActiveScreenTimeSettingsManager.shared

        switch command.type {
        case .lockDevice:
            settingsManager.lockAllApps()
        case .unlockAll:
            settingsManager.unlockAll()
        case .updateBlockedApps, .updateTimeLimits, .updateDowntime, .updateWebsites, .refreshSettings:
            guard let user = FirebaseAuthService.shared.currentUser else { break }
            let token = await FirebaseAuthService.shared.freshToken() ?? user.idToken
            if let config = await loadUserSettings(uid: user.uid, idToken: token) {
                settingsManager.applyRemoteConfiguration(config)
            }
        }

        await markCommandExecuted(command.id)
        lastSyncDate = Date()
    }

    // MARK: - DNS Tamper Detection

    private func checkDNSTamper(config: ScreenTimeConfiguration, uid: String, idToken: String) async {
        // Only relevant if admin enabled forceDNS and at least one of the tamper options
        guard config.forceDNS, config.dnsAlertOnRemoval || config.dnsAutoReapply else { return }

        #if !targetEnvironment(simulator)
        let isEnabled = await ContentBlockerService.shared.isDNSEnabled()
        guard !isEnabled else { return }  // DNS profile is still active — nothing to do

        // DNS was removed by the child
        if config.dnsAlertOnRemoval {
            await postTamperAlert(uid: uid, idToken: idToken,
                                  type: "dns_removed",
                                  message: "DNS filter profile was removed from the device.")
        }

        if config.dnsAutoReapply {
            // Re-installing will prompt the user to approve — child can decline,
            // but each attempt is logged and admin is still alerted above.
            await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID)
        }
        #endif
    }

    private func postTamperAlert(uid: String, idToken: String, type: String, message: String) async {
        let alert = TamperAlert(type: type, message: message, timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let encoded = try? encoder.encode(alert),
              let url = URL(string: "\(firebaseURL)/users/\(uid)/tamperAlerts.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Firebase REST Helpers

    private func firebaseGet(path: String, idToken: String? = nil) async throws -> Data {
        let url = try makeURL(for: path, idToken: idToken)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        return data
    }

    private func firebasePut(path: String, body: [String: Any], idToken: String? = nil) async throws {
        let url = try makeURL(for: path, idToken: idToken)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    private func firebasePost(path: String, body: [String: Any], idToken: String? = nil) async throws {
        let url = try makeURL(for: path, idToken: idToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    private func firebaseDelete(path: String, idToken: String? = nil) async throws {
        let url = try makeURL(for: path, idToken: idToken)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    private func makeURL(for path: String, idToken: String?) throws -> URL {
        let base = firebaseURL.hasSuffix("/") ? firebaseURL : firebaseURL + "/"
        var urlStr = "\(base)\(path).json"
        if let token = idToken, !token.isEmpty {
            urlStr += "?auth=\(token)"
        }
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        return url
    }

    // Keep old firebaseURL(for:) as alias for legacy call sites
    private func firebaseURL(for path: String) throws -> URL {
        try makeURL(for: path, idToken: FirebaseAuthService.shared.currentUser?.idToken)
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw URLError(.fileDoesNotExist) }
        guard 200..<300 ~= http.statusCode else {
            throw NSError(
                domain: "Firebase",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }
    }

    private func encodable<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
