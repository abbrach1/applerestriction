import Foundation
import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseDatabase

let adminEmail = "abbrachfeld@gmail.com"

@MainActor
class FirebaseAuthService: ObservableObject {
    static let shared = FirebaseAuthService()

    @Published var currentUser: FirebaseUser?
    @Published var isLoggedIn: Bool = false
    @Published var isAdmin: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    private init() {
        // Firebase Auth SDK maintains session across app launches automatically.
        // This listener fires immediately with the current user (or nil) and
        // again whenever sign-in state changes.
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let firebaseUser {
                    self.currentUser = FirebaseUser(uid: firebaseUser.uid,
                                                   email: firebaseUser.email ?? "")
                    self.isLoggedIn = true
                    self.isAdmin = (firebaseUser.email ?? "").lowercased() == adminEmail.lowercased()
                } else {
                    self.currentUser = nil
                    self.isLoggedIn = false
                    self.isAdmin = false
                }
            }
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            try await Auth.auth().signIn(withEmail: email, password: password)
            // authStateHandle updates currentUser/isLoggedIn/isAdmin
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    // MARK: - Sign Out

    func signOut() {
        try? Auth.auth().signOut()
        // authStateHandle clears currentUser/isLoggedIn/isAdmin
    }

    // MARK: - Token

    /// Returns a fresh ID token. Firebase SDK refreshes automatically if needed.
    /// Used by REST API calls in the admin dashboard.
    func freshToken() async -> String? {
        return try? await Auth.auth().currentUser?.getIDToken(forcingRefresh: false)
    }

    // MARK: - Admin: Create / Manage Managed Users

    /// Create a Firebase Auth user + a /users/{uid}/info node, without losing
    /// the admin's current sign-in session. We do the create against a secondary
    /// FirebaseApp instance and tear it down when done.
    func createManagedUser(email: String, password: String, displayName: String, deviceName: String) async throws -> String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedEmail.isEmpty, password.count >= 6 else {
            throw NSError(domain: "B-SAFE", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Email is required and password must be at least 6 characters."])
        }

        guard let primaryOptions = FirebaseApp.app()?.options else {
            throw NSError(domain: "B-SAFE", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Firebase not configured."])
        }

        let secondaryName = "bsafe-secondary-\(Int(Date().timeIntervalSince1970 * 1000))"
        FirebaseApp.configure(name: secondaryName, options: primaryOptions)
        guard let secondary = FirebaseApp.app(name: secondaryName) else {
            throw NSError(domain: "B-SAFE", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary Firebase app."])
        }
        let secondaryAuth = Auth.auth(app: secondary)

        defer {
            // Always tear down the secondary instance, even on error.
            Task { await secondary.delete() }
        }

        let result = try await secondaryAuth.createUser(withEmail: trimmedEmail, password: password)
        let uid = result.user.uid

        // Write the profile node so loadUsers picks it up immediately.
        let infoRef = Database.database(app: secondary).reference(withPath: "users/\(uid)/info")
        let payload: [String: Any] = [
            "email":          trimmedEmail,
            "displayName":    displayName.trimmingCharacters(in: .whitespaces),
            "deviceName":     deviceName.trimmingCharacters(in: .whitespaces),
            "isOnline":       false,
            "lastSeen":       Int(Date().timeIntervalSince1970 * 1000),
            "createdByAdmin": Auth.auth().currentUser?.uid ?? "",
            "createdAt":      Int(Date().timeIntervalSince1970 * 1000),
        ]
        try await infoRef.setValue(payload)

        try? secondaryAuth.signOut()
        return uid
    }

    /// Update a managed user's display / device name in Realtime DB.
    /// Email and password changes go through dedicated paths.
    func updateManagedUser(uid: String, displayName: String?, deviceName: String?) async throws {
        var patch: [String: Any] = [:]
        if let d = displayName { patch["displayName"] = d.trimmingCharacters(in: .whitespaces) }
        if let d = deviceName  { patch["deviceName"]  = d.trimmingCharacters(in: .whitespaces) }
        guard !patch.isEmpty else { return }
        try await Database.database().reference(withPath: "users/\(uid)/info").updateChildValues(patch)
    }

    /// Trigger a Firebase Auth password-reset email. The client SDK has no way
    /// to set a password directly for another user without the Admin SDK.
    func sendPasswordReset(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - Error Messages

    private func friendlyError(_ error: Error) -> String {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .wrongPassword, .invalidCredential:
            return "Incorrect email or password."
        case .userNotFound:
            return "No account found with that email."
        case .userDisabled:
            return "This account has been disabled."
        case .tooManyRequests:
            return "Too many attempts. Try again later."
        case .networkError:
            return "Connection failed. Check your internet."
        default:
            return "Login failed. Check your credentials."
        }
    }
}

// Simplified — no idToken/refreshToken stored; SDK manages tokens internally
struct FirebaseUser: Codable {
    let uid: String
    let email: String
    var displayName: String = ""

    // Backward compat: views that reference user.idToken get an empty string;
    // actual tokens always come from FirebaseAuthService.freshToken()
    var idToken: String { "" }
}
