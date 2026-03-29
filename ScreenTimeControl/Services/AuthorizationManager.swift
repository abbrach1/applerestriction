#if !targetEnvironment(simulator)

import Foundation
import FamilyControls
import Combine

/// Manages FamilyControls authorization for Screen Time access
@MainActor
class AuthorizationManager: ObservableObject {
    static let shared = AuthorizationManager()

    @Published var isAuthorized: Bool = false
    @Published var authorizationError: String?
    @Published var isRequesting: Bool = false

    private let center = AuthorizationCenter.shared

    private init() {
        // Check existing authorization status
        checkAuthorization()
    }

    func checkAuthorization() {
        switch center.authorizationStatus {
        case .approved:
            isAuthorized = true
        default:
            isAuthorized = false
        }
    }

    /// Request authorization as an individual (child's device) or parent
    func requestAuthorization() async {
        isRequesting = true
        authorizationError = nil

        do {
            // For individual/child device management
            try await center.requestAuthorization(for: .individual)
            isAuthorized = true
        } catch {
            authorizationError = "Authorization failed: \(error.localizedDescription)"
            isAuthorized = false
        }

        isRequesting = false
    }

    /// Request authorization as a parent (for Family Sharing)
    func requestParentAuthorization() async {
        isRequesting = true
        authorizationError = nil

        do {
            try await center.requestAuthorization(for: .child)
            isAuthorized = true
        } catch {
            authorizationError = "Parent authorization failed: \(error.localizedDescription)"
            isAuthorized = false
        }

        isRequesting = false
    }

    func revokeAuthorization() {
        center.revokeAuthorization(completionHandler: { result in
            Task { @MainActor in
                switch result {
                case .success:
                    self.isAuthorized = false
                case .failure(let error):
                    self.authorizationError = "Revoke failed: \(error.localizedDescription)"
                }
            }
        })
    }
}

#endif
