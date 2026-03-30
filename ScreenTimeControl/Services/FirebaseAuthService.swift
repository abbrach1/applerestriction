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
        // Restore session from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "auth.currentUser"),
           let user = try? JSONDecoder().decode(FirebaseUser.self, from: data) {
            self.currentUser = user
            self.isLoggedIn = true
            self.isAdmin = user.email.lowercased() == adminEmail.lowercased()
        }
    }

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
                          let returnedEmail = json["email"] as? String {
                    let user = FirebaseUser(uid: localId, email: returnedEmail, idToken: idToken)
                    currentUser = user
                    isLoggedIn = true
                    isAdmin = returnedEmail.lowercased() == adminEmail.lowercased()
                    if let encoded = try? JSONEncoder().encode(user) {
                        UserDefaults.standard.set(encoded, forKey: "auth.currentUser")
                    }
                }
            }
        } catch {
            errorMessage = "Connection failed. Check your internet."
        }

        isLoading = false
    }

    func signOut() {
        currentUser = nil
        isLoggedIn = false
        isAdmin = false
        UserDefaults.standard.removeObject(forKey: "auth.currentUser")
    }

    private func friendlyError(_ code: String) -> String {
        switch code {
        case "EMAIL_NOT_FOUND":       return "No account found with that email."
        case "INVALID_PASSWORD":      return "Incorrect password."
        case "USER_DISABLED":         return "This account has been disabled."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return "Too many attempts. Try again later."
        default:                      return "Login failed. Check your credentials."
        }
    }
}

struct FirebaseUser: Codable {
    let uid: String
    let email: String
    let idToken: String
}
