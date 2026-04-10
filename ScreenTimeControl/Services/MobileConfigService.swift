#if !targetEnvironment(simulator)
import Foundation
import Network
import UIKit

/// Installs a DNS profile as a .mobileconfig with a removal password via Safari.
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
            UserDefaults.standard.set(true, forKey: "bsafe.dns.usingMobileConfig")
            await UIApplication.shared.open(url)
        } catch {
            print("[MobileConfig] Server error: \(error)")
        }
    }

    // MARK: - Tamper Detection

    func isDNSActive(profileID: String) async -> Bool {
        guard let url = URL(string: "https://test.nextdns.io") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["nextdns"] as? Bool else { return false }
        if !profileID.isEmpty, let profile = json["profile"] as? String {
            return active && profile == profileID
        }
        return active
    }

    // MARK: - Profile Generation

    private func generateProfile(profileID: String, removalPassword: String) -> Data {
        let serverURL = profileID.isEmpty ? "https://dns.nextdns.io" : "https://dns.nextdns.io/\(profileID)"
        var profile: [String: Any] = [
            "PayloadContent": [[
                "PayloadType":        "com.apple.dnsSettings.managed",
                "PayloadVersion":     1,
                "PayloadIdentifier":  "com.abbrachfeld.bsafe.dns.settings",
                "PayloadUUID":        "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                "PayloadDisplayName": "B-SAFE DNS Settings",
                "DNSSettings": ["DNSProtocol": "HTTPS", "ServerURL": serverURL, "ServerName": "dns.nextdns.io"],
                "OnDemandRules": [["Action": "Connect"]]
            ]],
            "PayloadDisplayName":       "B-SAFE DNS Protection",
            "PayloadDescription":       "Keeps this device protected with content filtering.",
            "PayloadIdentifier":        "com.abbrachfeld.bsafe.dnsprofile",
            "PayloadRemovalDisallowed": false,
            "PayloadType":              "Configuration",
            "PayloadUUID":              "F1E2D3C4-B5A6-7890-1234-567890ABCDEF",
            "PayloadVersion":           1
        ]
        if !removalPassword.isEmpty { profile["RemovalPassword"] = removalPassword }
        return (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
    }

    // MARK: - Local HTTP Server

    private func startServer(serving data: Data) async throws -> UInt16 {
        // Capture self strongly so the listener stays alive through the async handoff
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: MCError.listenerFailed)
                return
            }
            guard let l = try? NWListener(using: .tcp) else {
                continuation.resume(throwing: MCError.listenerFailed)
                return
            }
            self.listener = l

            // stateUpdateHandler fires on the listener's queue (.main here).
            // Nil it out after first terminal state to guarantee single resume.
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready:
                    l?.stateUpdateHandler = nil
                    continuation.resume(returning: l?.port?.rawValue ?? 0)
                case .failed(let err):
                    l?.stateUpdateHandler = nil
                    continuation.resume(throwing: err)
                default:
                    break
                }
            }

            // newConnectionHandler runs on the listener queue; dispatch to MainActor
            // so handleConnection (which is @MainActor isolated) can be called safely.
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.handleConnection(conn, data: data)
                }
            }

            l.start(queue: .main)
        }
    }

    private func handleConnection(_ conn: NWConnection, data: Data) {
        conn.start(queue: .main)
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
