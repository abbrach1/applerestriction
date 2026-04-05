import Foundation
import Combine

private let firebaseAPIKey = "AIzaSyDQ1Om4fjR9Znj885klnTawL3SmOqKLRsk"
let adminEmail = "abbrachfeld@gmail.com"

@MainActor
class FirebaseAuthService: ObservableObject {
    static let shared = FirebaseAuthService()

    @Published var currentUser: FirebaseUser?
    @Published var isLoggedIn: Bool = false
    @Published var isAdmin: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "auth.currentUser"),
           let user = try? JSONDecoder().decode(FirebaseUser.self, from: data) {
            self.currentUser = user
            self.isLoggedIn = true
            self.isAdmin = user.email.lowercased() == adminEmail.lowercased()
            // Refresh token on restore since saved token may be expired
            Task { await self.refreshToken() }
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil

        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
            "returnSecureToken": true
        ])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errObj = json["error"] as? [String: Any],
                   let msg = errObj["message"] as? String {
                    errorMessage = friendlyError(msg)
                } else if let idToken = json["idToken"] as? String,
                          let localId = json["localId"] as? String,
                          let returnedEmail = json["email"] as? String,
                          let refreshToken = json["refreshToken"] as? String {
                    let user = FirebaseUser(uid: localId, email: returnedEmail, idToken: idToken, refreshToken: refreshToken)
                    saveUser(user)
                }
            }
        } catch {
            errorMessage = "Connection failed. Check your internet."
        }

        isLoading = false
    }

    // MARK: - Token Refresh

    func refreshToken() async {
        guard let user = currentUser, !user.refreshToken.isEmpty else { return }

        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(user.refreshToken)".data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newIdToken = json["id_token"] as? String,
               let newRefreshToken = json["refresh_token"] as? String {
                let updated = FirebaseUser(uid: user.uid, email: user.email, idToken: newIdToken, refreshToken: newRefreshToken)
                saveUser(updated)
            } else {
                // Refresh failed — sign out
                signOut()
            }
        } catch {}
    }

    /// Call this before any authenticated request to ensure token is fresh
    func freshToken() async -> String? {
        await refreshToken()
        return currentUser?.idToken
    }

    // MARK: - Sign Out

    func signOut() {
        currentUser = nil
        isLoggedIn = false
        isAdmin = false
        UserDefaults.standard.removeObject(forKey: "auth.currentUser")
    }

    // MARK: - Helpers

    private func saveUser(_ user: FirebaseUser) {
        currentUser = user
        isLoggedIn = true
        isAdmin = user.email.lowercased() == adminEmail.lowercased()
        if let encoded = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(encoded, forKey: "auth.currentUser")
        }
    }

    private func friendlyError(_ code: String) -> String {
        switch code {
        case "EMAIL_NOT_FOUND":             return "No account found with that email."
        case "INVALID_PASSWORD":            return "Incorrect password."
        case "USER_DISABLED":               return "This account has been disabled."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return "Too many attempts. Try again later."
        default:                            return "Login failed. Check your credentials."
        }
    }
}

struct FirebaseUser: Codable {
    let uid: String
    let email: String
    let idToken: String
    let refreshToken: String
}
