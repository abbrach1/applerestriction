import Foundation
import Combine
import FirebaseAuth

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
