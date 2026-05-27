#if !targetEnvironment(simulator)

import Foundation
import Network
import Combine
import UIKit

/// Detects probable captive-portal Wi-Fi networks and surfaces a prompt so the
/// child can authenticate. Necessary because B-SAFE's forced DNS-over-HTTPS
/// profile prevents the device from completing the captive portal handshake
/// (DoH can't resolve until the portal is satisfied — classic chicken-and-egg).
///
/// Strategy: combine three signals.
///   1. NWPathMonitor — we're on Wi-Fi and the path is satisfied.
///   2. RemoteSyncService.isOnline — Firebase WebSocket cannot connect.
///   3. Time — both above true for ≥8 s consecutively.
/// When all three line up, `showPrompt` flips to true and the child UI shows a
/// sheet. The Open Login Page button kicks Safari at a known plain URL; iOS's
/// built-in captive-network support then takes over and renders the portal.
@MainActor
class CaptivePortalDetector: ObservableObject {
    static let shared = CaptivePortalDetector()

    @Published var showPrompt: Bool = false

    private var monitor: NWPathMonitor?
    private var debounceTimer: Timer?
    private var onWifi: Bool = false
    private var firebaseOnline: Bool = true
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    func start() {
        // Watch network type (Wi-Fi vs cellular).
        monitor?.cancel()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let wifi = path.usesInterfaceType(.wifi) && path.status == .satisfied
                self?.onWifi = wifi
                if !wifi {
                    // Cellular / no Wi-Fi → not a captive scenario.
                    self?.cancelDebounce()
                    self?.showPrompt = false
                }
                self?.reevaluate()
            }
        }
        m.start(queue: .global())
        monitor = m

        // Mirror Firebase reachability into our local flag.
        RemoteSyncService.shared.$isOnline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] online in
                self?.firebaseOnline = online
                self?.reevaluate()
            }
            .store(in: &cancellables)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        cancellables.removeAll()
        cancelDebounce()
        showPrompt = false
    }

    /// Open Safari to a plain URL. iOS will detect the captive portal and
    /// render the native authentication sheet; once the user signs in, the
    /// portal releases the device and DoH starts resolving again.
    func openCaptivePortal() {
        guard let url = URL(string: "http://captive.apple.com/") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Private

    private func reevaluate() {
        if onWifi && !firebaseOnline {
            // Both true — wait ~8 s before prompting so we don't flicker on
            // brief reconnects (DNS profile reapply, Wi-Fi roam, etc.).
            if debounceTimer == nil {
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.onWifi && !self.firebaseOnline {
                            self.showPrompt = true
                        }
                        self.debounceTimer = nil
                    }
                }
            }
        } else {
            cancelDebounce()
            showPrompt = false
        }
    }

    private func cancelDebounce() {
        debounceTimer?.invalidate()
        debounceTimer = nil
    }
}

#endif
