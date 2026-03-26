import Foundation
import Combine
import UIKit

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

    /// Firebase Realtime Database URL
    private static let defaultFirebaseURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    var firebaseURL: String {
        get { UserDefaults.standard.string(forKey: "remote.firebaseURL") ?? Self.defaultFirebaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "remote.firebaseURL") }
    }

    private var deviceId: String { DeviceInfo.current.id }

    private var pollTimer: Timer?

    private init() {
        isPaired = UserDefaults.standard.bool(forKey: "remote.isPaired")
        pairingCode = UserDefaults.standard.string(forKey: "remote.pairingCode") ?? ""
        if let saved = UserDefaults.standard.data(forKey: "remote.connectedDevices"),
           let devices = try? JSONDecoder().decode([DeviceInfo].self, from: saved) {
            connectedDevices = devices
        }
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

    /// Child → fetches all unexecuted commands from Firebase
    func checkForCommands() async -> [RemoteCommand] {
        do {
            let data = try await firebaseGet(path: "devices/\(deviceId)/commands")
            // Firebase returns a dict of {pushId: command}
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }

            var commands: [RemoteCommand] = []
            for (_, value) in dict {
                if let cmdData = try? JSONSerialization.data(withJSONObject: value),
                   let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: cmdData),
                   !cmd.executed {
                    commands.append(cmd)
                }
            }

            pendingCommands = commands
            return commands
        } catch {
            return []
        }
    }

    /// Child → marks a command as done by deleting it from Firebase
    func markCommandExecuted(_ commandId: String) async {
        // Find and delete the command node
        // We stored commandId in the object — use a query to find its Firebase key
        // Simplest: just delete all executed commands by re-fetching and deleting matches
        if let data = try? await firebaseGet(path: "devices/\(deviceId)/commands"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (pushKey, value) in dict {
                if let cmdData = try? JSONSerialization.data(withJSONObject: value),
                   let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: cmdData),
                   cmd.id == commandId {
                    try? await firebaseDelete(path: "devices/\(deviceId)/commands/\(pushKey)")
                }
            }
        }
    }

    // MARK: - Polling

    /// Child device: start polling Firebase for new commands
    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        // Run immediately, then repeat
        Task { await pollAndExecute() }
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
    }

    private func executeCommand(_ command: RemoteCommand) async {
        let settingsManager = ActiveScreenTimeSettingsManager.shared

        switch command.type {
        case .lockDevice:
            settingsManager.lockAllApps()
        case .unlockAll:
            settingsManager.unlockAll()
        case .updateBlockedApps, .updateTimeLimits, .updateDowntime, .refreshSettings:
            if let config = await pullSettings() {
                settingsManager.applyRemoteConfiguration(config)
            }
        }

        await markCommandExecuted(command.id)
    }

    // MARK: - Firebase REST Helpers

    private func firebaseGet(path: String) async throws -> Data {
        let url = try firebaseURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        return data
    }

    private func firebasePut(path: String, body: [String: Any]) async throws {
        let url = try firebaseURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    private func firebasePost(path: String, body: [String: Any]) async throws {
        let url = try firebaseURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    private func firebaseDelete(path: String) async throws {
        let url = try firebaseURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
    }

    private func firebaseURL(for path: String) throws -> URL {
        guard !firebaseURL.isEmpty else {
            throw NSError(
                domain: "RemoteSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase URL not set. Go to Settings and enter your Firebase database URL."]
            )
        }
        let base = firebaseURL.hasSuffix("/") ? firebaseURL : firebaseURL + "/"
        guard let url = URL(string: "\(base)\(path).json") else {
            throw URLError(.badURL)
        }
        return url
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
