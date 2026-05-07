#if !targetEnvironment(simulator)

import Foundation
import FamilyControls
import Combine

/// Manages FamilyControls authorization for Screen Time access
@MainActor
class AuthorizationManager: ObservableObject {
    static let shared = AuthorizationManager()

    @Published var isAuthorized: Bool
    @Published var authorizationError: String?
    @Published var isRequesting: Bool = false

    private let center = AuthorizationCenter.shared
    private var cancellables = Set<AnyCancellable>()

    private static let authorizedCacheKey = "bsafe.familyControlsAuthorized"

    private init() {
        // Optimistically restore the last-known authorization state so that we
        // don't flash the "Set Up This Device" prompt on cold launch while
        // FamilyControls is still settling. The system publisher below will
        // correct this if the user revoked authorization in Settings.
        let cached = UserDefaults.standard.bool(forKey: Self.authorizedCacheKey)
        self.isAuthorized = cached

        applyStatus(center.authorizationStatus)

        center.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyStatus(status)
            }
            .store(in: &cancellables)
    }

    func checkAuthorization() {
        applyStatus(center.authorizationStatus)
    }

    private func applyStatus(_ status: AuthorizationStatus) {
        let approved = (status == .approved)
        if approved != isAuthorized {
            isAuthorized = approved
        }
        UserDefaults.standard.set(approved, forKey: Self.authorizedCacheKey)
    }

    /// Request authorization as an individual (child's device) or parent
    func requestAuthorization() async {
        isRequesting = true
        authorizationError = nil

        do {
            // For individual/child device management
            try await center.requestAuthorization(for: .individual)
            applyStatus(center.authorizationStatus)
        } catch {
            authorizationError = "Authorization failed: \(error.localizedDescription)"
            applyStatus(center.authorizationStatus)
        }

        isRequesting = false
    }

    /// Request authorization as a parent (for Family Sharing)
    func requestParentAuthorization() async {
        isRequesting = true
        authorizationError = nil

        do {
            try await center.requestAuthorization(for: .child)
            applyStatus(center.authorizationStatus)
        } catch {
            authorizationError = "Parent authorization failed: \(error.localizedDescription)"
            applyStatus(center.authorizationStatus)
        }

        isRequesting = false
    }

    func revokeAuthorization() {
        center.revokeAuthorization(completionHandler: { result in
            Task { @MainActor in
                switch result {
                case .success:
                    self.applyStatus(self.center.authorizationStatus)
                case .failure(let error):
                    self.authorizationError = "Revoke failed: \(error.localizedDescription)"
                }
            }
        })
    }
}

#endif
