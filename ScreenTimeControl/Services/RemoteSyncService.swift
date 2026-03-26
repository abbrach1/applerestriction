import Foundation
import Combine
import UIKit

/// Service that syncs Screen Time settings with a remote server for remote control
/// Uses a simple REST API — replace the base URL with your own backend
@MainActor
class RemoteSyncService: ObservableObject {
    static let shared = RemoteSyncService()

    @Published var isPaired: Bool = false
    @Published var pairingCode: String = ""
    @Published var connectedDevices: [DeviceInfo] = []
    @Published var pendingCommands: [RemoteCommand] = []
    @Published var lastSyncDate: Date?
    @Published var syncError: String?

    // MARK: - Configuration

    /// Base URL for the remote control API
    /// Replace with your actual server URL (e.g., Firebase Functions, your own server)
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "remote.baseURL")
            ?? "https://your-server.com/api"
    }

    private var deviceId: String {
        DeviceInfo.current.id
    }

    private var pollTimer: Timer?

    private init() {
        isPaired = UserDefaults.standard.bool(forKey: "remote.isPaired")
        pairingCode = UserDefaults.standard.string(forKey: "remote.pairingCode") ?? ""
    }

    // MARK: - Pairing

    /// Generate a pairing code for this device so a parent can connect
    func generatePairingCode() async {
        let code = String(format: "%06d", Int.random(in: 100000...999999))
        pairingCode = code

        let body: [String: Any] = [
            "code": code,
            "device": encodableDict(from: DeviceInfo.current)
        ]

        do {
            let _ = try await postRequest(endpoint: "/devices/register", body: body)
            UserDefaults.standard.set(code, forKey: "remote.pairingCode")
            UserDefaults.standard.set(true, forKey: "remote.isPaired")
            isPaired = true
        } catch {
            syncError = "Failed to register device: \(error.localizedDescription)"
        }
    }

    /// Pair with a child's device using their code (parent side)
    func pairWithDevice(code: String) async {
        let body: [String: Any] = [
            "code": code,
            "parentDevice": encodableDict(from: DeviceInfo.current)
        ]

        do {
            let data = try await postRequest(endpoint: "/devices/pair", body: body)
            if let response = try? JSONDecoder().decode(DeviceInfo.self, from: data) {
                connectedDevices.append(response)
                isPaired = true
                UserDefaults.standard.set(true, forKey: "remote.isPaired")
            }
        } catch {
            syncError = "Failed to pair: \(error.localizedDescription)"
        }
    }

    // MARK: - Syncing Settings

    /// Push current settings to the server
    func pushSettings(_ config: ScreenTimeConfiguration) async {
        let body = encodableDict(from: config)

        do {
            let _ = try await postRequest(
                endpoint: "/devices/\(deviceId)/settings",
                body: body
            )
            lastSyncDate = Date()
            syncError = nil
        } catch {
            syncError = "Push failed: \(error.localizedDescription)"
        }
    }

    /// Pull settings from the server (child device)
    func pullSettings() async -> ScreenTimeConfiguration? {
        do {
            let data = try await getRequest(endpoint: "/devices/\(deviceId)/settings")
            let config = try JSONDecoder().decode(ScreenTimeConfiguration.self, from: data)
            lastSyncDate = Date()
            syncError = nil
            return config
        } catch {
            syncError = "Pull failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Remote Commands

    /// Send a command to a paired device (parent side)
    func sendCommand(_ command: RemoteCommand, toDevice targetDeviceId: String) async {
        let body = encodableDict(from: command)

        do {
            let _ = try await postRequest(
                endpoint: "/devices/\(targetDeviceId)/commands",
                body: body
            )
        } catch {
            syncError = "Command failed: \(error.localizedDescription)"
        }
    }

    /// Check for pending commands (child device)
    func checkForCommands() async -> [RemoteCommand] {
        do {
            let data = try await getRequest(endpoint: "/devices/\(deviceId)/commands/pending")
            let commands = try JSONDecoder().decode([RemoteCommand].self, from: data)
            pendingCommands = commands
            return commands
        } catch {
            return []
        }
    }

    /// Mark a command as executed
    func markCommandExecuted(_ commandId: String) async {
        let _ = try? await postRequest(
            endpoint: "/devices/\(deviceId)/commands/\(commandId)/executed",
            body: [:]
        )
    }

    // MARK: - Polling

    /// Start polling for remote commands (runs on child device)
    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let commands = await self.checkForCommands()
                for command in commands where !command.executed {
                    await self.executeCommand(command)
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Execute a remote command locally
    private func executeCommand(_ command: RemoteCommand) async {
        let settingsManager = ScreenTimeSettingsManager.shared

        switch command.type {
        case .lockDevice:
            settingsManager.lockAllApps()
        case .unlockAll:
            settingsManager.unlockAll()
        case .updateBlockedApps, .updateTimeLimits, .updateDowntime:
            if let config = await pullSettings() {
                settingsManager.applyRemoteConfiguration(config)
            }
        case .refreshSettings:
            if let config = await pullSettings() {
                settingsManager.applyRemoteConfiguration(config)
            }
        }

        await markCommandExecuted(command.id)
    }

    // MARK: - Networking Helpers

    private func getRequest(endpoint: String) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    private func postRequest(endpoint: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    private func encodableDict<T: Encodable>(from value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
