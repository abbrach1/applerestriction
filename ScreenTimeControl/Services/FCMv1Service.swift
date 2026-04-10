import Foundation
import Security

/// Sends FCM push notifications via the HTTP v1 API using a service account.
///
/// Setup (one-time, admin device only):
///   1. Firebase Console → Project Settings → Service Accounts
///      → Generate new private key → download JSON
///   2. In Xcode, add a new file: FCMServiceAccount.plist
///      Add two keys from the downloaded JSON:
///        client_email  →  firebase-adminsdk-xxx@applerestrictions.iam.gserviceaccount.com
///        private_key   →  -----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n
///   3. Make sure FCMServiceAccount.plist is in the main app target (not BSAFEContentFilter)
///
/// The PROJECT_ID is read automatically from GoogleService-Info.plist.
@MainActor
class FCMv1Service {
    static let shared = FCMv1Service()

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    private init() {}

    // MARK: - Public

    func send(to fcmToken: String, title: String, body: String) async {
        do {
            let accessToken = try await getAccessToken()
            let projectID   = googleServiceInfoValue(forKey: "PROJECT_ID") ?? ""
            guard !projectID.isEmpty else {
                print("[FCMv1] PROJECT_ID not found in GoogleService-Info.plist"); return
            }
            let urlStr = "https://fcm.googleapis.com/v1/projects/\(projectID)/messages:send"
            guard let url = URL(string: urlStr) else { return }

            let payload: [String: Any] = [
                "message": [
                    "token": fcmToken,
                    "notification": ["title": title, "body": body],
                    "apns": [
                        "headers": ["apns-priority": "10"],
                        "payload": ["aps": ["sound": "default", "content-available": 1]]
                    ]
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json",       forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (respData, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let msg = String(data: respData, encoding: .utf8) ?? ""
                print("[FCMv1] Send failed \(http.statusCode): \(msg)")
            }
        } catch {
            print("[FCMv1] Error: \(error)")
        }
    }

    // MARK: - OAuth2 Access Token

    private func getAccessToken() async throws -> String {
        // Return cached token if still valid (with 5-min buffer)
        if let token = cachedToken, tokenExpiry > Date().addingTimeInterval(300) {
            return token
        }
        let creds = try loadCredentials()
        let jwt   = try makeJWT(clientEmail: creds.clientEmail, privateKey: creds.privateKey)
        let token = try await exchangeJWTForToken(jwt: jwt)
        cachedToken  = token.accessToken
        tokenExpiry  = Date().addingTimeInterval(TimeInterval(token.expiresIn - 60))
        return token.accessToken
    }

    // MARK: - Service Account plist

    private struct Credentials {
        let clientEmail: String
        let privateKey: String
    }

    private func loadCredentials() throws -> Credentials {
        guard let path = Bundle.main.path(forResource: "FCMServiceAccount", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String],
              let email = dict["client_email"], !email.isEmpty,
              let key   = dict["private_key"],  !key.isEmpty
        else {
            throw FCMError.missingCredentials
        }
        return Credentials(clientEmail: email, privateKey: key)
    }

    // MARK: - JWT (RS256)

    private func makeJWT(clientEmail: String, privateKey: String) throws -> String {
        let header = base64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let now    = Int(Date().timeIntervalSince1970)
        let claimsStr = """
        {"iss":"\(clientEmail)","scope":"https://www.googleapis.com/auth/firebase.messaging",\
        "aud":"https://oauth2.googleapis.com/token","iat":\(now),"exp":\(now + 3600)}
        """
        let claims       = base64url(Data(claimsStr.utf8))
        let signingInput = "\(header).\(claims)"

        let secKey    = try importPrivateKey(pem: privateKey)
        var cfError: Unmanaged<CFError>?
        guard let sigData = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &cfError
        ) else {
            throw FCMError.signingFailed(cfError?.takeRetainedValue().localizedDescription ?? "")
        }
        return "\(signingInput).\(base64url(sigData as Data))"
    }

    // MARK: - RSA Key Import (PKCS#8 PEM → SecKey)

    private func importPrivateKey(pem: String) throws -> SecKey {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----",     with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----",       with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----",   with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: stripped) else {
            throw FCMError.invalidPrivateKey
        }
        // Firebase service accounts use PKCS#8; extract inner PKCS#1 RSA key
        let keyData = extractPKCS1(fromPKCS8: derData) ?? derData

        let attrs: [String: Any] = [
            kSecAttrKeyType  as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &err) else {
            throw FCMError.keyImportFailed(err?.takeRetainedValue().localizedDescription ?? "")
        }
        return key
    }

    /// Strips the PKCS#8 ASN.1 wrapper to return the inner PKCS#1 RSA private key bytes.
    private func extractPKCS1(fromPKCS8 data: Data) -> Data? {
        var bytes = Array(data)
        var i = 0

        func readLen() -> Int {
            guard i < bytes.count else { return 0 }
            if bytes[i] < 0x80 { let l = Int(bytes[i]); i += 1; return l }
            let n = Int(bytes[i] & 0x7f); i += 1
            var len = 0
            for _ in 0..<n {
                guard i < bytes.count else { return 0 }
                len = (len << 8) | Int(bytes[i]); i += 1
            }
            return len
        }

        // SEQUENCE (outer)
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }
        i += 1; _ = readLen()
        // INTEGER version (0)
        guard i < bytes.count, bytes[i] == 0x02 else { return nil }
        i += 1; i += readLen()
        // SEQUENCE AlgorithmIdentifier
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }
        i += 1; i += readLen()
        // OCTET STRING containing the PKCS#1 key
        guard i < bytes.count, bytes[i] == 0x04 else { return nil }
        i += 1; _ = readLen()
        return Data(bytes[i...])
    }

    // MARK: - Token Exchange

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in:   Int
        var accessToken:  String { access_token }
        var expiresIn:    Int    { expires_in }
    }

    private func exchangeJWTForToken(jwt: String) async throws -> TokenResponse {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw FCMError.invalidURL
        }
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Helpers

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func googleServiceInfoValue(forKey key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any]
        else { return nil }
        return dict[key] as? String
    }
}

// MARK: - Errors

enum FCMError: Error {
    case missingCredentials
    case invalidPrivateKey
    case keyImportFailed(String)
    case signingFailed(String)
    case invalidURL
}
