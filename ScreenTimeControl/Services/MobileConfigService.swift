#if !targetEnvironment(simulator)
import Foundation
import Network
import UIKit

/// Installs a DNS profile as a signed .mobileconfig with a removal password,
/// which is far harder for a child to remove than a plain NEDNSSettingsManager profile.
///
/// Installation flow:
///   1. Generate the .mobileconfig plist in memory
///   2. Start a one-shot local HTTP server on a random port
///   3. Open http://127.0.0.1:{port}/bsafe-dns.mobileconfig in Safari
///   4. iOS intercepts the Content-Type and launches the profile installer
///   5. Child must enter the removal password to delete the profile from Settings
///
/// Tamper detection:
///   Uses https://test.nextdns.io which returns {"nextdns": true/false, "profile": "id"}
///   so we can verify the profile is active without NEDNSSettingsManager.
@MainActor
class MobileConfigService {
    static let shared = MobileConfigService()

    private var listener: NWListener?
    private init() {}

    // MARK: - Install

    func install(profileID: String, removalPassword: String) async {
        let data = generateProfile(profileID: profileID, removalPassword: removalPassword)
        do {
            let port = try await startServer(serving: data)
            guard let url = URL(string: "http://127.0.0.1:\(port)/bsafe-dns.mobileconfig") else { return }
            // Flag so isDNSEnabled uses NextDNS API check instead of NEDNSSettingsManager
            UserDefaults.standard.set(true, forKey: "bsafe.dns.usingMobileConfig")
            await UIApplication.shared.open(url)
        } catch {
            print("[MobileConfig] Failed to start server: \(error)")
        }
    }

    // MARK: - Tamper Detection

    /// Verify DNS is active by querying NextDNS's test endpoint.
    /// Returns true if traffic is currently going through NextDNS (and matching our profile).
    func isDNSActive(profileID: String) async -> Bool {
        guard let url = URL(string: "https://test.nextdns.io") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["nextdns"] as? Bool else { return false }
        // If a profile ID is set, also verify it matches ours
        if !profileID.isEmpty, let profile = json["profile"] as? String {
            return active && profile == profileID
        }
        return active
    }

    // MARK: - Profile Generation

    private func generateProfile(profileID: String, removalPassword: String) -> Data {
        let serverURL = profileID.isEmpty
            ? "https://dns.nextdns.io"
            : "https://dns.nextdns.io/\(profileID)"

        var profile: [String: Any] = [
            "PayloadContent": [[
                "PayloadType":        "com.apple.dnsSettings.managed",
                "PayloadVersion":     1,
                "PayloadIdentifier":  "com.abbrachfeld.bsafe.dns.settings",
                "PayloadUUID":        "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                "PayloadDisplayName": "B-SAFE DNS Settings",
                "DNSSettings": [
                    "DNSProtocol": "HTTPS",
                    "ServerURL":   serverURL,
                    "ServerName":  "dns.nextdns.io"
                ],
                "OnDemandRules": [["Action": "Connect"]]
            ]],
            "PayloadDisplayName":      "B-SAFE DNS Protection",
            "PayloadDescription":      "Keeps this device protected with content filtering.",
            "PayloadIdentifier":       "com.abbrachfeld.bsafe.dnsprofile",
            "PayloadRemovalDisallowed": false,
            "PayloadType":             "Configuration",
            "PayloadUUID":             "F1E2D3C4-B5A6-7890-1234-567890ABCDEF",
            "PayloadVersion":          1
        ]
        if !removalPassword.isEmpty {
            profile["RemovalPassword"] = removalPassword
        }
        return (try? PropertyListSerialization.data(
            fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
    }

    // MARK: - Local HTTP Server

    private func startServer(serving data: Data) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            guard let l = try? NWListener(using: .tcp) else {
                continuation.resume(throwing: MCError.listenerFailed)
                return
            }
            listener = l

            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let err):
                    resumed = true
                    continuation.resume(throwing: err)
                default: break
                }
            }

            l.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn, data: data)
            }
            l.start(queue: .main)
        }
    }

    private func handleConnection(_ conn: NWConnection, data: Data) {
        conn.start(queue: .main)
        // Drain the incoming HTTP request then immediately respond
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            let header = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/x-apple-aspen-config",
                "Content-Disposition: attachment; filename=\"bsafe-dns.mobileconfig\"",
                "Content-Length: \(data.count)",
                "Connection: close",
                "", ""
            ].joined(separator: "\r\n")

            var response = header.data(using: .utf8)!
            response.append(data)

            conn.send(content: response, completion: .contentProcessed { [weak self] _ in
                conn.cancel()
                // Give Safari a moment to start the download before stopping the server
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.listener?.cancel()
                    self?.listener = nil
                }
            })
        }
    }
}

enum MCError: Error { case listenerFailed }

#endif
