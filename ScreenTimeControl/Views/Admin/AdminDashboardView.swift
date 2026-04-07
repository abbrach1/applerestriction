import SwiftUI
#if !targetEnvironment(simulator)
import FamilyControls
#endif

// MARK: - User List ViewModel

@MainActor
class AdminViewModel: ObservableObject {
    @Published var users: [ManagedUser] = []
    @Published var isLoading = false

    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    func deleteUser(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        users.removeAll { $0.uid == uid }
    }

    func loadUsers(idToken: String) async {
        isLoading = true
        guard let url = URL(string: "\(dbURL)/users.json?auth=\(idToken)") else { isLoading = false; return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            users = dict.compactMap { uid, val in
                guard let userNode = val as? [String: Any],
                      let info = userNode["info"] as? [String: Any],
                      let email = info["email"] as? String else { return nil }
                return ManagedUser(
                    uid: uid,
                    email: email,
                    displayName: info["displayName"] as? String ?? "",
                    deviceName: info["deviceName"] as? String ?? "Unknown Device",
                    isOnline: info["isOnline"] as? Bool ?? false,
                    lastSeen: info["lastSeen"] as? String ?? ""
                )
            }.sorted { a, b in
                if a.isOnline != b.isOnline { return a.isOnline }
                return a.lastSeen > b.lastSeen
            }
        }
        isLoading = false
    }
}

// MARK: - Per-User Settings ViewModel

@MainActor
class AdminUserViewModel: ObservableObject {
    @Published var config = ScreenTimeConfiguration()
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var savedSection: String?
    @Published var lastError: String?
    @Published var appListReport: AppListReport?
    @Published var websiteSetupInfo: WebsiteSetupInfo?
    @Published var tamperAlerts: [(pushKey: String, alert: TamperAlert)] = []
    @Published var unlockRequests: [(pushKey: String, request: UnlockRequest)] = []
    @Published var websiteRequests: [(pushKey: String, request: WebsiteRequest)] = []

    var pendingRequestCount: Int { unlockRequests.count + websiteRequests.count }

    struct WebsiteSetupInfo {
        let siteCount: Int
        let categoryCount: Int
        let timestamp: Date
    }

    #if !targetEnvironment(simulator)
    @Published var appSelection = FamilyActivitySelection()
    #endif

    var hasAppSelection: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !appSelection.applicationTokens.isEmpty || !appSelection.categoryTokens.isEmpty
        #endif
    }

    var appSelectionSummary: String {
        #if targetEnvironment(simulator)
        return "Requires real device"
        #else
        let apps = appSelection.applicationTokens.count
        let cats = appSelection.categoryTokens.count
        if apps == 0 && cats == 0 { return "No apps blocked" }
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if cats > 0 { parts.append("\(cats) categor\(cats == 1 ? "y" : "ies")") }
        return parts.joined(separator: ", ") + " blocked"
        #endif
    }

    func serializeAppSelection() {
        #if !targetEnvironment(simulator)
        if let data = try? JSONEncoder().encode(appSelection) {
            config.blockedAppsSelectionData = data.base64EncodedString()
        }
        #endif
    }

    func clearAppSelection() {
        config.blockedAppsSelectionData = nil
        #if !targetEnvironment(simulator)
        appSelection = FamilyActivitySelection()
        #endif
    }

    private func deserializeAppSelection() {
        #if !targetEnvironment(simulator)
        guard let base64 = config.blockedAppsSelectionData,
              let data = Data(base64Encoded: base64),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return }
        appSelection = selection
        #endif
    }

    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    // MARK: - Local persistence (survives Firebase failures)

    private func localKey(uid: String) -> String { "admin.config.\(uid)" }

    private func saveLocally(uid: String) {
        if let data = try? encoder.encode(config) {
            UserDefaults.standard.set(data, forKey: localKey(uid: uid))
        }
    }

    private func loadLocally(uid: String) {
        if let data = UserDefaults.standard.data(forKey: localKey(uid: uid)),
           let saved = try? decoder.decode(ScreenTimeConfiguration.self, from: data) {
            config = saved
            deserializeAppSelection()
        }
    }

    // MARK: - Load

    func load(uid: String, idToken: String) async {
        // Show local copy immediately — no blank flash while waiting for network
        loadLocally(uid: uid)
        isLoading = true
        lastError = nil

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadSettings(uid: uid, idToken: idToken) }
            group.addTask { await self.loadAppList(uid: uid, idToken: idToken) }
            group.addTask { await self.loadWebsiteSetup(uid: uid, idToken: idToken) }
            group.addTask { await self.loadTamperAlerts(uid: uid, idToken: idToken) }
            group.addTask { await self.loadUnlockRequests(uid: uid, idToken: idToken) }
            group.addTask { await self.loadWebsiteRequests(uid: uid, idToken: idToken) }
        }

        isLoading = false
    }

    private func loadSettings(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/settings.json?auth=\(idToken)") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                lastError = "Session expired — try signing out and back in"
                return
            }
            if let remote = try? decoder.decode(ScreenTimeConfiguration.self, from: data) {
                config = remote
                saveLocally(uid: uid)
                deserializeAppSelection()
            }
        } catch {
            lastError = "Could not reach Firebase: \(error.localizedDescription)"
        }
    }

    func loadAppList(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/appList.json?auth=\(idToken)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let report = try? decoder.decode(AppListReport.self, from: data) {
            appListReport = report
        }
    }

    func loadWebsiteSetup(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/websiteSetup.json?auth=\(idToken)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let sites = dict["siteCount"] as? Int ?? 0
            let cats  = dict["categoryCount"] as? Int ?? 0
            let ms    = dict["timestamp"] as? Double ?? 0
            websiteSetupInfo = WebsiteSetupInfo(
                siteCount: sites,
                categoryCount: cats,
                timestamp: Date(timeIntervalSince1970: ms / 1000)
            )
        }
    }

    func loadTamperAlerts(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/tamperAlerts.json?auth=\(idToken)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        var results: [(pushKey: String, alert: TamperAlert)] = []
        for (key, val) in dict {
            if let d = try? JSONSerialization.data(withJSONObject: val),
               let alert = try? dec.decode(TamperAlert.self, from: d),
               !alert.dismissed {
                results.append((pushKey: key, alert: alert))
            }
        }
        tamperAlerts = results.sorted { $0.alert.timestamp > $1.alert.timestamp }
    }

    func dismissTamperAlert(pushKey: String, uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/tamperAlerts/\(pushKey).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        tamperAlerts.removeAll { $0.pushKey == pushKey }
    }

    func loadUnlockRequests(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/unlockRequests.json?auth=\(idToken)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        var results: [(pushKey: String, request: UnlockRequest)] = []
        for (key, val) in dict {
            if let d = try? JSONSerialization.data(withJSONObject: val),
               let req = try? dec.decode(UnlockRequest.self, from: d) {
                results.append((pushKey: key, request: req))
            }
        }
        unlockRequests = results.sorted { $0.request.timestamp > $1.request.timestamp }
    }

    func approveUnlockRequest(pushKey: String, uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/unlockRequests/\(pushKey).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        unlockRequests.removeAll { $0.pushKey == pushKey }
        await sendCommand(.unlockAll, uid: uid, idToken: idToken)
        await sendFCMToChild(uid: uid, idToken: idToken,
                             title: "✅ Unlock Approved",
                             body: "Your admin approved your unlock request.")
    }

    func denyUnlockRequest(pushKey: String, uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/unlockRequests/\(pushKey).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        unlockRequests.removeAll { $0.pushKey == pushKey }
        await sendFCMToChild(uid: uid, idToken: idToken,
                             title: "❌ Unlock Denied",
                             body: "Your admin denied your unlock request.")
    }

    func deleteUser(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    func loadWebsiteRequests(uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/websiteRequests.json?auth=\(idToken)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .millisecondsSince1970
        var results: [(pushKey: String, request: WebsiteRequest)] = []
        for (key, val) in dict {
            if let d = try? JSONSerialization.data(withJSONObject: val),
               let req = try? dec.decode(WebsiteRequest.self, from: d) {
                results.append((pushKey: key, request: req))
            }
        }
        websiteRequests = results.sorted { $0.request.timestamp > $1.request.timestamp }
    }

    func approveWebsiteRequest(pushKey: String, domain: String, uid: String, idToken: String) async {
        // Add to allowed list if not already there
        if !config.allowedWebsites.contains(domain) {
            config.allowedWebsites.append(domain)
        }
        // Switch to whitelist mode so the domain is actually enforced (and visible in the list)
        config.websiteFilterMode = .whitelist
        // Save updated settings to Firebase
        await saveAndSendCommand(.updateWebsites, uid: uid, idToken: idToken, section: "website_approved")
        // Delete the request
        guard let url = URL(string: "\(dbURL)/users/\(uid)/websiteRequests/\(pushKey).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        websiteRequests.removeAll { $0.pushKey == pushKey }
        await sendFCMToChild(uid: uid, idToken: idToken,
                             title: "✅ Website Approved",
                             body: "\(domain) has been added to your allowed sites.")
    }

    func denyWebsiteRequest(pushKey: String, uid: String, idToken: String) async {
        guard let url = URL(string: "\(dbURL)/users/\(uid)/websiteRequests/\(pushKey).json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        websiteRequests.removeAll { $0.pushKey == pushKey }
        await sendFCMToChild(uid: uid, idToken: idToken,
                             title: "❌ Website Denied",
                             body: "Your admin denied access to the requested website.")
    }

    /// Queues a notification for the child device at /users/{uid}/notifications/{autoId}.
    /// The child's background sync task reads this node and fires a local UNNotification,
    /// then deletes the entry. No Firebase Messaging SDK required.
    private func sendFCMToChild(uid: String, idToken: String, title: String, body: String) async {
        let notification: [String: Any] = [
            "title": title,
            "body": body,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: notification),
              let url = URL(string: "\(dbURL)/users/\(uid)/notifications.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payloadData
        _ = try? await URLSession.shared.data(for: req)
    }

    func setEmergencyBypassCode(_ code: EmergencyBypassCode, uid: String, idToken: String) async {
        guard let encoded = try? encoder.encode(code),
              let url = URL(string: "\(dbURL)/users/\(uid)/emergencyBypass.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)
    }

    func markAppListReviewed(uid: String, idToken: String) async {
        guard var report = appListReport else { return }
        report.reviewed = true
        appListReport = report
        guard let encoded = try? encoder.encode(report),
              let url = URL(string: "\(dbURL)/users/\(uid)/appList.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Save & Command

    func saveAndSendCommand(_ commandType: RemoteCommand.CommandType, uid: String, idToken: String, section: String) async {
        isSaving = true
        lastError = nil

        guard let encoded = try? encoder.encode(config),
              let url = URL(string: "\(dbURL)/users/\(uid)/settings.json?auth=\(idToken)") else {
            lastError = "Failed to encode settings"
            isSaving = false; return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                lastError = "Save failed (HTTP \(http.statusCode)) — try again"
                isSaving = false; return
            }
            // Save succeeded — persist locally too
            saveLocally(uid: uid)
        } catch {
            lastError = "Network error: \(error.localizedDescription)"
            isSaving = false; return
        }

        await sendCommand(commandType, uid: uid, idToken: idToken)
        savedSection = section
        isSaving = false
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if savedSection == section { savedSection = nil }
    }

    func sendCommand(_ type: RemoteCommand.CommandType, uid: String, idToken: String) async {
        let cmd = RemoteCommand(type: type)
        guard let encoded = try? encoder.encode(cmd),
              let url = URL(string: "\(dbURL)/users/\(uid)/commands.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Admin Dashboard (User List)

struct AdminDashboardView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @StateObject private var vm = AdminViewModel()
    @State private var showFCMSettings = false
    @State private var fcmServerKey = ""
    @State private var fcmSaved = false
    @State private var nextDNSApiKey = ""
    @State private var nextDNSSaved = false

    private var onlineCount: Int { vm.users.filter(\.isOnline).count }
    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    private func userInitials(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading users...")
                } else if vm.users.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("No Users Yet").font(.headline)
                        Text("Add users in Firebase Console under Authentication.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                } else {
                    List {
                        ForEach(vm.users) { user in
                            NavigationLink {
                                AdminUserControlView(user: user)
                                    .environmentObject(auth)
                            } label: {
                                HStack(spacing: 12) {
                                    // Initials avatar
                                    ZStack {
                                        Circle()
                                            .fill(user.isOnline
                                                  ? Color(red: 0, green: 0.4, blue: 0.15).opacity(0.12)
                                                  : Color(.systemGray5))
                                            .frame(width: 44, height: 44)
                                        Text(userInitials(user.primaryLabel))
                                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                                            .foregroundStyle(user.isOnline
                                                             ? Color(red: 0, green: 0.4, blue: 0.15)
                                                             : .secondary)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(user.isOnline ? .green : Color(.systemGray4))
                                            .frame(width: 11, height: 11)
                                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(user.primaryLabel)
                                            .font(.subheadline).fontWeight(.semibold)
                                        Text(user.deviceName.isEmpty ? user.secondaryLabel : user.deviceName)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if user.isOnline {
                                        Text("Online")
                                            .font(.caption2).fontWeight(.medium)
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Color.green.opacity(0.1), in: Capsule())
                                    } else if !user.lastSeen.isEmpty {
                                        Text(relativeLastSeen(user.lastSeen))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task {
                                        let token = await auth.freshToken() ?? ""
                                        await vm.deleteUser(uid: user.uid, idToken: token)
                                        let refreshToken = await auth.freshToken() ?? ""
                                        await vm.loadUsers(idToken: refreshToken)
                                    }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("B-SAFE Admin")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        if onlineCount > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 7, height: 7)
                                Text("\(onlineCount) online")
                                    .font(.caption).fontWeight(.medium).foregroundStyle(.green)
                            }
                        }
                        Button {
                            Task {
                                let token = await auth.freshToken() ?? ""
                                await vm.loadUsers(idToken: token)
                            }
                        } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("Sign Out", role: .destructive) { auth.signOut() }
                        Button { showFCMSettings = true } label: {
                            Label("Notification Settings", systemImage: "bell.badge")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showFCMSettings) {
                NavigationStack {
                    Form {
                        Section {
                            SecureField("FCM Server Key", text: $fcmServerKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } header: {
                            Text("Push Notifications to Admin")
                        } footer: {
                            Text("Get this from Firebase Console → Project Settings → Cloud Messaging → Server Key. Enables push notifications to your phone when a child sends an unlock or website request.")
                                .font(.caption)
                        }

                        Section {
                            Button {
                                Task {
                                    let token = await auth.freshToken() ?? ""
                                    await saveFCMServerKey(token: token)
                                    fcmSaved = true
                                    _ = try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    fcmSaved = false
                                }
                            } label: {
                                HStack {
                                    Image(systemName: fcmSaved ? "checkmark.circle.fill" : "icloud.and.arrow.up")
                                    Text(fcmSaved ? "Saved!" : "Save Server Key")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(fcmSaved ? Color.green : Color(red: 0, green: 0.4, blue: 0.15))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .disabled(fcmServerKey.isEmpty)
                        }

                        Section {
                            SecureField("NextDNS API Key", text: $nextDNSApiKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } header: {
                            Text("NextDNS API Key")
                        } footer: {
                            Text("Get this from nextdns.io → Account → API. Entered once and applies to all child profiles.")
                                .font(.caption)
                        }

                        Section {
                            Button {
                                Task {
                                    let token = await auth.freshToken() ?? ""
                                    await saveNextDNSApiKey(token: token)
                                    nextDNSSaved = true
                                    _ = try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    nextDNSSaved = false
                                }
                            } label: {
                                HStack {
                                    Image(systemName: nextDNSSaved ? "checkmark.circle.fill" : "icloud.and.arrow.up")
                                    Text(nextDNSSaved ? "Saved!" : "Save API Keys")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(nextDNSSaved ? Color.green : Color(red: 0, green: 0.4, blue: 0.15))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .disabled(fcmServerKey.isEmpty && nextDNSApiKey.isEmpty)
                        }

                        Section("About FCM Token") {
                            Text("Your device's FCM token is automatically registered when you open the admin dashboard. No extra steps needed — just enter the server key above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("API Keys & Notifications")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showFCMSettings = false }
                        }
                    }
                }
            }
            .task {
                // Load keys from UserDefaults first (instant, no network)
                if let local = UserDefaults.standard.string(forKey: "bsafe.fcmServerKey"), !local.isEmpty {
                    fcmServerKey = local
                }
                if let local = UserDefaults.standard.string(forKey: "bsafe.nextDNSApiKey"), !local.isEmpty {
                    nextDNSApiKey = local
                }
                let token = await auth.freshToken() ?? ""
                await vm.loadUsers(idToken: token)
                // Then refresh from Firebase (may be newer)
                if let url = URL(string: "\(dbURL)/adminConfig/fcmServerKey.json?auth=\(token)"),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let key = try? JSONDecoder().decode(String.self, from: data),
                   !key.isEmpty {
                    fcmServerKey = key
                    UserDefaults.standard.set(key, forKey: "bsafe.fcmServerKey")
                }
                if let url = URL(string: "\(dbURL)/adminConfig/nextDNSApiKey.json?auth=\(token)"),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let key = try? JSONDecoder().decode(String.self, from: data),
                   !key.isEmpty {
                    nextDNSApiKey = key
                    UserDefaults.standard.set(key, forKey: "bsafe.nextDNSApiKey")
                }
            }
        }
    }

    private func saveNextDNSApiKey(token: String) async {
        let trimmed = nextDNSApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: "bsafe.nextDNSApiKey")
            if let url = URL(string: "\(dbURL)/adminConfig/nextDNSApiKey.json?auth=\(token)") {
                var req = URLRequest(url: url)
                req.httpMethod = "PUT"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = "\"\(trimmed)\"".data(using: .utf8)
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        // Also save FCM key if set
        let fcmTrimmed = fcmServerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fcmTrimmed.isEmpty {
            UserDefaults.standard.set(fcmTrimmed, forKey: "bsafe.fcmServerKey")
            if let url = URL(string: "\(dbURL)/adminConfig/fcmServerKey.json?auth=\(token)") {
                var req = URLRequest(url: url)
                req.httpMethod = "PUT"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = "\"\(fcmTrimmed)\"".data(using: .utf8)
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    private func saveFCMServerKey(token: String) async {
        let trimmed = fcmServerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Save locally so it persists without network
        UserDefaults.standard.set(trimmed, forKey: "bsafe.fcmServerKey")
        // Also push to Firebase so other devices can sync
        guard let url = URL(string: "\(dbURL)/adminConfig/fcmServerKey.json?auth=\(token)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "\"\(trimmed)\"".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Admin User Control View (Full Settings Editor)

struct AdminUserControlView: View {
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @StateObject private var vm = AdminUserViewModel()
    @State private var selectedTab = 0
    @State private var nextDNSApiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            // User header
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.primaryLabel)
                        .font(.subheadline).fontWeight(.medium)
                    Text(user.secondaryLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(user.isOnline ? .green : .gray)
                        .frame(width: 7, height: 7)
                    Text(user.isOnline ? "Online" : "Offline")
                        .font(.caption2)
                        .foregroundStyle(user.isOnline ? .green : .secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.quaternary)

            // Error banner
            if let err = vm.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.red)
            }

            // Tamper alert banners
            ForEach(vm.tamperAlerts, id: \.pushKey) { item in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tamper Detected")
                            .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                        Text(item.alert.message)
                            .font(.caption2).foregroundStyle(.white.opacity(0.9))
                        Text(item.alert.timestamp.formatted(.relative(presentation: .named)))
                            .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Button {
                        Task {
                            let token = await auth.freshToken() ?? ""
                            await vm.dismissTamperAlert(pushKey: item.pushKey, uid: user.uid, idToken: token)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)
            }

            // Scrollable tab picker (7 tabs)
            let tabs: [(Int, String, String)] = [
                (0, "bell.badge.fill",                  "Requests"),
                (1, "globe",                            "Websites"),
                (2, "moon.fill",                        "Downtime"),
                (3, "square.grid.2x2.fill",             "Apps"),
                (4, "bolt.fill",                        "Commands"),
                (5, "network.badge.shield.half.filled", "DNS"),
                (6, "info.circle.fill",                 "Info"),
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.0) { tag, icon, label in
                        Button { selectedTab = tag } label: {
                            VStack(spacing: 3) {
                                Image(systemName: icon)
                                    .font(.system(size: 14, weight: .medium))
                                Text(label)
                                    .font(.caption2).fontWeight(.medium)
                            }
                            .foregroundStyle(selectedTab == tag ? Color(red: 0, green: 0.4, blue: 0.15) : .secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundStyle(selectedTab == tag
                                                     ? Color(red: 0, green: 0.4, blue: 0.15)
                                                     : .clear),
                                alignment: .bottom
                            )
                        }
                        .overlay(alignment: .topTrailing) {
                            if tag == 0 && vm.pendingRequestCount > 0 {
                                Text("\(vm.pendingRequestCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.red, in: Capsule())
                                    .offset(x: 2, y: 2)
                            }
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
            .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator)), alignment: .bottom)
            .padding(.top, 4)

            if vm.isLoading {
                Spacer()
                ProgressView("Loading settings...")
                Spacer()
            } else {
                TabView(selection: $selectedTab) {
                    RequestsTab(vm: vm, user: user).tag(0)
                    WebsiteTab(vm: vm, user: user, globalApiKey: nextDNSApiKey).tag(1)
                    DowntimeTab(vm: vm, user: user).tag(2)
                    AppsTab(vm: vm, user: user).tag(3)
                    CommandsTab(vm: vm, user: user).tag(4)
                    DNSTab(vm: vm, user: user, globalApiKey: nextDNSApiKey).tag(5)
                    InfoTab(user: user).tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle(user.primaryLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let token = await auth.freshToken() ?? ""
            await vm.load(uid: user.uid, idToken: token)
            if let local = UserDefaults.standard.string(forKey: "bsafe.nextDNSApiKey"), !local.isEmpty {
                nextDNSApiKey = local
            }
        }
    }
}

// MARK: - Requests Tab

struct RequestsTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService

    var body: some View {
        if vm.unlockRequests.isEmpty && vm.websiteRequests.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52)).foregroundStyle(.green)
                Text("No Pending Requests")
                    .font(.headline)
                Text("Unlock and website access requests from this device appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !vm.unlockRequests.isEmpty {
                    Section {
                        ForEach(vm.unlockRequests, id: \.pushKey) { item in
                            requestCard(
                                icon: "lock.open.fill", iconColor: .orange,
                                title: item.request.deviceName.isEmpty ? "Unknown Device" : item.request.deviceName,
                                subtitle: item.request.timestamp.formatted(.relative(presentation: .named)),
                                reason: item.request.reason
                            ) {
                                Task {
                                    let token = await auth.freshToken() ?? ""
                                    await vm.approveUnlockRequest(pushKey: item.pushKey, uid: user.uid, idToken: token)
                                }
                            } onDeny: {
                                Task {
                                    let token = await auth.freshToken() ?? ""
                                    await vm.denyUnlockRequest(pushKey: item.pushKey, uid: user.uid, idToken: token)
                                }
                            }
                        }
                    } header: { Label("Unlock Requests", systemImage: "lock.open.fill") }
                      footer: { Text("Approve sends an unlock command. Device responds within 30 seconds.") }
                }

                if !vm.websiteRequests.isEmpty {
                    Section {
                        ForEach(vm.websiteRequests, id: \.pushKey) { item in
                            requestCard(
                                icon: "globe.badge.exclamationmark", iconColor: .blue,
                                title: item.request.domain,
                                subtitle: "\(item.request.deviceName.isEmpty ? "Unknown" : item.request.deviceName) · \(item.request.timestamp.formatted(.relative(presentation: .named)))",
                                reason: item.request.reason
                            ) {
                                Task {
                                    let token = await auth.freshToken() ?? ""
                                    await vm.approveWebsiteRequest(
                                        pushKey: item.pushKey,
                                        domain: item.request.domain,
                                        uid: user.uid, idToken: token)
                                }
                            } onDeny: {
                                Task {
                                    let token = await auth.freshToken() ?? ""
                                    await vm.denyWebsiteRequest(pushKey: item.pushKey, uid: user.uid, idToken: token)
                                }
                            }
                        }
                    } header: { Label("Website Requests", systemImage: "globe.badge.exclamationmark") }
                      footer: { Text("Approve adds the site to their whitelist and enables whitelist mode.") }
                }
            }
        }
    }

    @ViewBuilder
    private func requestCard(icon: String, iconColor: Color, title: String, subtitle: String,
                             reason: String, onApprove: @escaping () -> Void, onDeny: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(iconColor.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 15, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).fontWeight(.semibold)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !reason.isEmpty {
                Text("\"\(reason)\"")
                    .font(.caption).foregroundStyle(.secondary).italic()
                    .padding(.leading, 46)
            }
            HStack(spacing: 10) {
                Button(action: onApprove) {
                    Text("Approve").font(.subheadline).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(.green).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Button(action: onDeny) {
                    Text("Deny").font(.subheadline).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.red.opacity(0.12)).foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Info Tab

struct InfoTab: View {
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @State private var info: [String: Any] = [:]
    @State private var isLoading = true
    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading device info...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Device") {
                        infoRow("Name",       value: info["deviceName"] as? String ?? user.deviceName,          icon: "iphone",           color: .blue)
                        infoRow("Model",      value: info["deviceModel"] as? String ?? "—",                     icon: "cpu.fill",          color: .purple)
                        infoRow("iOS",        value: (info["systemVersion"] as? String).map { "iOS \($0)" } ?? "—", icon: "applelogo",    color: .primary)
                        infoRow("Device ID",  value: (info["deviceId"] as? String).map { String($0.prefix(14)) + "…" } ?? "—", icon: "barcode", color: .secondary)
                    }

                    Section("Power & Storage") {
                        let batteryLevel = info["batteryLevel"] as? Double ?? -1
                        let batteryState = info["batteryState"] as? String ?? "unknown"
                        if batteryLevel >= 0 {
                            HStack {
                                Image(systemName: batteryIcon(state: batteryState, level: batteryLevel))
                                    .foregroundStyle(batteryColor(level: batteryLevel)).frame(width: 28)
                                Text("Battery")
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int(batteryLevel * 100))%")
                                        .fontWeight(.semibold).foregroundStyle(batteryColor(level: batteryLevel))
                                    if batteryState == "charging" {
                                        Label("Charging", systemImage: "bolt.fill").font(.caption2).foregroundStyle(.green)
                                    }
                                }
                            }
                            ProgressView(value: batteryLevel)
                                .tint(batteryColor(level: batteryLevel))
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        }

                        let storageTotal = info["storageTotal"] as? Int64 ?? 0
                        let storageFree  = info["storageFree"]  as? Int64 ?? 0
                        if storageTotal > 0 {
                            let used     = storageTotal - storageFree
                            let usedGB   = Double(used) / 1_000_000_000
                            let totalGB  = Double(storageTotal) / 1_000_000_000
                            let fraction = Double(used) / Double(storageTotal)
                            HStack {
                                Image(systemName: "internaldrive.fill").foregroundStyle(.orange).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Storage")
                                        Spacer()
                                        Text(String(format: "%.1f / %.0f GB", usedGB, totalGB))
                                            .font(.subheadline).fontWeight(.medium)
                                    }
                                    ProgressView(value: fraction)
                                        .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .blue)
                                }
                            }
                        }
                    }

                    Section("Connectivity") {
                        HStack {
                            Circle().fill(user.isOnline ? .green : Color(.systemGray4)).frame(width: 8, height: 8)
                            Text(user.isOnline ? "Online" : "Offline")
                                .foregroundStyle(user.isOnline ? .green : .secondary)
                            Spacer()
                            if !user.lastSeen.isEmpty {
                                Text(relativeLastSeen(user.lastSeen))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Account") {
                        infoRow("Email",   value: user.email,                                            icon: "envelope.fill",         color: .blue)
                        infoRow("User ID", value: String(user.uid.prefix(14)) + "…",                    icon: "person.badge.key.fill",  color: .secondary)
                    }
                }
            }
        }
        .task { await loadInfo() }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 28)
            Text(label)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func batteryIcon(state: String, level: Double) -> String {
        if state == "charging" || state == "full" { return "battery.100.bolt" }
        if level > 0.75 { return "battery.100" }
        if level > 0.50 { return "battery.75" }
        if level > 0.25 { return "battery.50" }
        return "battery.25"
    }

    private func batteryColor(level: Double) -> Color {
        level > 0.5 ? .green : level > 0.2 ? .yellow : .red
    }

    private func loadInfo() async {
        isLoading = true
        let token = await auth.freshToken() ?? ""
        guard let url = URL(string: "\(dbURL)/users/\(user.uid)/info.json?auth=\(token)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isLoading = false; return
        }
        info = dict
        isLoading = false
    }
}

// MARK: - Website Tab

struct WebsiteTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    let globalApiKey: String
    @EnvironmentObject var auth: FirebaseAuthService
    @State private var newDomain = ""
    @State private var newPendingDomain = ""
    @State private var isSendingDomain = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        List {
            // Child device setup status
            if let info = vm.websiteSetupInfo {
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Device whitelist configured")
                                .font(.subheadline).fontWeight(.medium)
                            Text("\(info.siteCount) site\(info.siteCount == 1 ? "" : "s") · \(info.categoryCount) categories")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(info.timestamp.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Child Device Setup")
                } footer: {
                    Text("Child ran Website Whitelist Setup on their device. Switching to 'Allow Only Listed Sites' will allow exactly those sites.")
                }
            }

            Section {
                Picker("Filter Mode", selection: $vm.config.websiteFilterMode) {
                    Text("Block Listed Sites").tag(WebFilterMode.blacklist)
                    Text("Allow Only Listed Sites").tag(WebFilterMode.whitelist)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } header: {
                Text("Mode")
            } footer: {
                if vm.config.websiteFilterMode == .blacklist {
                    Text("Blacklist: listed sites are blocked. Empty list = unrestricted browsing.")
                        .font(.caption)
                } else if vm.websiteSetupInfo != nil {
                    Text("Whitelist: only the sites configured on the child's device are allowed. All others are blocked.")
                        .font(.caption)
                } else {
                    Text("Whitelist: ALL websites will be blocked until the child runs Website Whitelist Setup on their device.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            // DNS Settings — prominently placed so they're easy to find
            Section {
                Toggle(isOn: $vm.config.forceDNS) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Force NextDNS")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Blocks domains system-wide across all apps, not just Safari")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.purple)
                    }
                }

                if vm.config.forceDNS {
                    HStack {
                        Image(systemName: "person.badge.key.fill").foregroundStyle(.purple).frame(width: 28)
                        TextField("NextDNS Profile ID (e.g. abc123)", text: $vm.config.nextDNSProfileID)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).font(.subheadline)
                    }
                    Toggle(isOn: $vm.config.dnsAlertOnRemoval) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alert Me If Removed").font(.subheadline).fontWeight(.medium)
                                Text("Sends a tamper alert if the child removes the DNS profile")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "bell.badge.fill").foregroundStyle(.orange) }
                    }
                    Toggle(isOn: $vm.config.dnsAutoReapply) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto Re-Apply If Removed").font(.subheadline).fontWeight(.medium)
                                Text("Attempts to reinstall the profile automatically (child must approve)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.green) }
                    }
                }
            } header: {
                Text("DNS Filter")
            } footer: {
                if vm.config.forceDNS {
                    Text("Find your Profile ID at nextdns.io → your profile → Setup.")
                        .font(.caption)
                } else {
                    Text("NextDNS blocks domains system-wide across all apps. Toggle on to configure.")
                        .font(.caption)
                }
            }

            if vm.config.websiteFilterMode == .blacklist {
                Section("Blocked Sites") {
                    ForEach(vm.config.blockedWebsites, id: \.self) { domain in
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(domain).font(.subheadline)
                        }
                    }
                    .onDelete { indices in
                        vm.config.blockedWebsites.remove(atOffsets: indices)
                    }

                    HStack {
                        TextField("Add domain (e.g. youtube.com)", text: $newDomain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .focused($inputFocused)
                        Button("Add") {
                            let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
                                .replacingOccurrences(of: "https://", with: "")
                                .replacingOccurrences(of: "http://", with: "")
                                .replacingOccurrences(of: "www.", with: "")
                            if !domain.isEmpty && !vm.config.blockedWebsites.contains(domain) {
                                vm.config.blockedWebsites.append(domain)
                                newDomain = ""
                            }
                        }
                        .disabled(newDomain.isEmpty)
                    }
                }
            } else {
                Section("Allowed Sites") {
                    ForEach(vm.config.allowedWebsites, id: \.self) { domain in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(domain).font(.subheadline)
                        }
                    }
                    .onDelete { indices in
                        vm.config.allowedWebsites.remove(atOffsets: indices)
                    }

                    HStack {
                        TextField("Add domain (e.g. google.com)", text: $newDomain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .focused($inputFocused)
                        Button("Add") {
                            let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
                                .replacingOccurrences(of: "https://", with: "")
                                .replacingOccurrences(of: "http://", with: "")
                                .replacingOccurrences(of: "www.", with: "")
                            if !domain.isEmpty && !vm.config.allowedWebsites.contains(domain) {
                                vm.config.allowedWebsites.append(domain)
                                newDomain = ""
                            }
                        }
                        .disabled(newDomain.isEmpty)
                    }
                }
            }

            // Block a specific website immediately
            Section {
                HStack {
                    TextField("domain (e.g. tiktok.com)", text: $newPendingDomain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button {
                        Task { await sendWebsiteToDevice() }
                    } label: {
                        if isSendingDomain { ProgressView() }
                        else { Text("Block") }
                    }
                    .disabled(newPendingDomain.trimmingCharacters(in: .whitespaces).isEmpty || isSendingDomain)
                }
            } header: {
                Text("Quick Block")
            } footer: {
                Text("Adds the domain to the blocked list and applies it immediately — no action needed from the child.")
            }

            Section {
                Toggle(isOn: $vm.config.browserEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("B-SAFE Browser")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Show the built-in browser tab on the child's device")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "globe.badge.checkmark").foregroundStyle(.green)
                    }
                }
            } header: { Text("Browser") } footer: {
                Text("When enabled, the child can browse only the allowed sites using the B-SAFE Browser. Disable to remove the browser tab entirely.")
                    .font(.caption)
            }

            Section {
                Toggle(isOn: $vm.config.contentBlockerEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Safari Content Blocker")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Enforces allow/block list inside Safari using plain domain names")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "safari.fill").foregroundStyle(.blue)
                    }
                }
            } header: { Text("Extra Protection") }

            Section {
                ApplyButton(label: "Apply Website Settings",
                            icon: "globe",
                            color: .blue,
                            section: "websites",
                            vm: vm) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        await vm.saveAndSendCommand(.updateWebsites, uid: user.uid, idToken: token, section: "websites")
                        // Sync to NextDNS if configured
                        let effectiveKey = globalApiKey.isEmpty ? vm.config.nextDNSApiKey : globalApiKey
                        if vm.config.forceDNS && !vm.config.nextDNSProfileID.isEmpty && !effectiveKey.isEmpty {
                            let result = await NextDNSService.shared.sync(
                                profileID: vm.config.nextDNSProfileID,
                                apiKey: effectiveKey,
                                allowedDomains: vm.config.allowedWebsites,
                                blockedDomains: vm.config.blockedWebsites,
                                whitelistMode: vm.config.websiteFilterMode == .whitelist
                            )
                            if !result.success, let err = result.error {
                                vm.lastError = "NextDNS sync failed: \(err)"
                            }
                        }
                    }
                }

                let effectiveKey = globalApiKey.isEmpty ? vm.config.nextDNSApiKey : globalApiKey
                if vm.config.forceDNS && !vm.config.nextDNSProfileID.isEmpty && !effectiveKey.isEmpty {
                    NextDNSSyncStatusRow(vm: vm, globalApiKey: effectiveKey)
                }
            }
        }
    }

    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    private func cleanDomain(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: "/").first ?? raw
    }

    private func sendWebsiteToDevice() async {
        let domain = cleanDomain(newPendingDomain)
        guard !domain.isEmpty else { return }
        guard !vm.config.blockedWebsites.contains(domain) else {
            newPendingDomain = ""
            return
        }
        isSendingDomain = true
        vm.config.blockedWebsites.append(domain)
        // Switch to blacklist mode if currently in whitelist mode
        if vm.config.websiteFilterMode == .whitelist {
            vm.config.websiteFilterMode = .blacklist
        }
        let token = await auth.freshToken() ?? ""
        await vm.saveAndSendCommand(.updateWebsites, uid: user.uid, idToken: token, section: "websites")
        newPendingDomain = ""
        isSendingDomain = false
    }
}

// MARK: - Downtime Tab

struct DowntimeTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService

    private let days = ["S", "M", "T", "W", "T", "F", "S"]
    private let dayNumbers = [1, 2, 3, 4, 5, 6, 7]  // Sunday=1 ... Saturday=7

    var startTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: vm.config.downtimeSchedule.startHour,
                                                            minute: vm.config.downtimeSchedule.startMinute)) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                vm.config.downtimeSchedule.startHour = c.hour ?? 22
                vm.config.downtimeSchedule.startMinute = c.minute ?? 0
            }
        )
    }

    var endTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: vm.config.downtimeSchedule.endHour,
                                                            minute: vm.config.downtimeSchedule.endMinute)) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                vm.config.downtimeSchedule.endHour = c.hour ?? 7
                vm.config.downtimeSchedule.endMinute = c.minute ?? 0
            }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle("Enable Downtime", isOn: $vm.config.downtimeEnabled)
            } footer: {
                Text("During downtime, all apps and websites are blocked.")
            }

            if vm.config.downtimeEnabled {
                Section("Schedule") {
                    DatePicker("Start Time", selection: startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End Time", selection: endTime, displayedComponents: .hourAndMinute)
                }

                Section("Active Days") {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            let dayNum = dayNumbers[i]
                            let isActive = vm.config.downtimeSchedule.activeDays.contains(dayNum)
                            Button {
                                if isActive {
                                    vm.config.downtimeSchedule.activeDays.remove(dayNum)
                                } else {
                                    vm.config.downtimeSchedule.activeDays.insert(dayNum)
                                }
                            } label: {
                                Text(days[i])
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(isActive ? Color(red: 0, green: 0.4, blue: 0.15) : Color.gray.opacity(0.15))
                                    .foregroundStyle(isActive ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                ApplyButton(label: vm.config.downtimeEnabled ? "Apply Downtime Schedule" : "Disable Downtime",
                            icon: "moon.fill",
                            color: .purple,
                            section: "downtime",
                            vm: vm) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        await vm.saveAndSendCommand(.updateDowntime, uid: user.uid, idToken: token, section: "downtime")
                    }
                }
            }
        }
    }
}

// MARK: - Apps Tab

// Local model for iTunes Search API results — not stored in Firebase
struct AppSearchResult: Identifiable {
    let id: String        // trackId as String
    let name: String
    let iconURL: String
    let category: String
    let sellerName: String
}

struct AppsTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @State private var showingPicker = false

    // App search / push state
    @State private var appSearchQuery = ""
    @State private var searchResults: [AppSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var pendingApps: [String: RecommendedApp] = [:]
    @State private var pushingAppID: String?   // appStoreID currently being sent
    @FocusState private var searchFocused: Bool

    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    var body: some View {
        List {
            // Recommend App section
            Section {
                HStack {
                    TextField("Search App Store...", text: $appSearchQuery)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($searchFocused)
                        .onSubmit { Task { await searchApps() } }
                    Button {
                        Task { await searchApps() }
                    } label: {
                        if isSearching { ProgressView().scaleEffect(0.8) }
                        else { Text("Search") }
                    }
                    .disabled(appSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }

                if let err = searchError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                ForEach(searchResults) { result in
                    HStack(spacing: 10) {
                        AsyncImage(url: URL(string: result.iconURL)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.gray.opacity(0.2))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.subheadline).fontWeight(.medium)
                            Text(result.category)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await pushApp(result) }
                        } label: {
                            if pushingAppID == result.id {
                                ProgressView().scaleEffect(0.8)
                            } else if pendingApps.values.contains(where: { $0.appStoreID == result.id }) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("Send")
                                    .font(.caption).fontWeight(.semibold)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundStyle(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .disabled(pushingAppID == result.id ||
                                  pendingApps.values.contains(where: { $0.appStoreID == result.id }))
                    }
                }

                if !pendingApps.isEmpty {
                    ForEach(Array(pendingApps), id: \.key) { pushKey, app in
                        HStack(spacing: 10) {
                            AsyncImage(url: URL(string: app.iconURL)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2))
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.appName).font(.subheadline)
                                Text("Pending on device").font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task { await removePendingApp(pushKey: pushKey) }
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Recommend an App")
            } footer: {
                Text("Search the App Store and send apps directly to this device. The child will see them and can install with one tap inside B-SAFE.")
            }

            // App Review Request (child-submitted)
            if let report = vm.appListReport {
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(report.reviewed ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: report.reviewed ? "checkmark.circle.fill" : "clock.badge.exclamationmark.fill")
                                .foregroundStyle(report.reviewed ? .green : .orange)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(report.reviewed ? "App List Reviewed" : "Pending App Review")
                                .font(.subheadline).fontWeight(.medium)
                            Text("\(report.appCount) apps · \(report.categoryCount) categories")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(report.timestamp.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !report.reviewed {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                        }
                    }
                    .padding(.vertical, 2)

                    if !report.reviewed {
                        Button {
                            Task {
                                let token = await auth.freshToken() ?? ""
                                await vm.markAppListReviewed(uid: user.uid, idToken: token)
                            }
                        } label: {
                            Label("Mark as Reviewed", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("App Review Request")
                } footer: {
                    Text("Child sent their app list for review. After reviewing, use the picker below to block specific apps.")
                }
            }

            Section {
                Toggle(isOn: $vm.config.blockNewApps) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Block New App Installs")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Prevents the device from installing any new apps")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "xmark.app.fill").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("App Installations")
            } footer: {
                Text("When enabled, the child must send their app list for your review before you can approve new apps.")
            }

            Section {
                Button {
                    showingPicker = true
                } label: {
                    HStack {
                        Image(systemName: "app.badge.checkmark").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Select Apps to Block")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(vm.appSelectionSummary)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if vm.hasAppSelection {
                    Button("Clear App Selection", role: .destructive) {
                        vm.clearAppSelection()
                    }
                }
            } header: {
                Text("Block Specific Apps")
            } footer: {
                Text("All apps are allowed by default. Selected apps will show a blocking screen on the device. Note: this picker shows your device's apps — use the child-side Admin Setup to pick from the child's installed apps.")
            }

            Section("Emergency Lock") {
                Toggle(isOn: $vm.config.isLocked) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Block ALL Apps")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Overrides individual selections")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.red)
                    }
                }
            }

            Section {
                ApplyButton(label: "Apply App Settings",
                            icon: "checkmark.shield.fill",
                            color: .orange,
                            section: "apps",
                            vm: vm) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        let cmd: RemoteCommand.CommandType = vm.config.isLocked ? .lockDevice : .updateBlockedApps
                        await vm.saveAndSendCommand(cmd, uid: user.uid, idToken: token, section: "apps")
                    }
                }
            }
        }
        #if !targetEnvironment(simulator)
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                FamilyActivityPicker(selection: $vm.appSelection)
                    .navigationTitle("Select Apps to Block")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                vm.serializeAppSelection()
                                showingPicker = false
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingPicker = false }
                        }
                    }
            }
        }
        #endif
        .task {
            let token = await auth.freshToken() ?? ""
            await vm.loadAppList(uid: user.uid, idToken: token)
            await loadPendingApps()
        }
    }
}

// MARK: - CommandsTab helpers

extension CommandsTab {
    func sendNotification() async {
        let body = notifBody.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        isSendingNotif = true

        let token = await auth.freshToken() ?? ""
        let note = AdminNotification(
            title: notifTitle.trimmingCharacters(in: .whitespaces),
            body: body,
            timestamp: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let encoded = try? encoder.encode(note),
              let url = URL(string: "https://applerestrictions-default-rtdb.firebaseio.com/users/\(user.uid)/notifications.json?auth=\(token)") else {
            isSendingNotif = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)

        notifTitle = ""
        notifBody = ""
        notifBodyFocused = false
        isSendingNotif = false
        notifSent = true
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        notifSent = false
    }
}

// MARK: - Emergency Bypass Code Section

struct EmergencyBypassSection: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var generatedCode: String = ""
    @State private var selectedDuration: Int = 30   // minutes
    @State private var isSending = false
    @State private var codeSent = false

    private let durations = [(15, "15 min"), (30, "30 min"), (60, "1 hour"), (120, "2 hours")]

    var body: some View {
        Section {
            if codeSent && !generatedCode.isEmpty {
                VStack(spacing: 8) {
                    Text("Emergency Code")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(formattedCode)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                        .tracking(8)
                    Text("Valid for \(durationLabel) · One-time use")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Picker("Duration", selection: $selectedDuration) {
                ForEach(durations, id: \.0) { mins, label in
                    Text(label).tag(mins)
                }
            }

            Button {
                let code = String(format: "%06d", Int.random(in: 0...999999))
                generatedCode = code
                let bypass = EmergencyBypassCode(
                    code: code,
                    durationMinutes: selectedDuration,
                    createdAt: Date(),
                    used: false
                )
                Task {
                    isSending = true
                    let token = await auth.freshToken() ?? ""
                    await vm.setEmergencyBypassCode(bypass, uid: user.uid, idToken: token)
                    codeSent = true
                    isSending = false
                }
            } label: {
                HStack {
                    if isSending { ProgressView().tint(.white) }
                    else { Image(systemName: codeSent ? "arrow.triangle.2.circlepath" : "key.fill") }
                    Text(codeSent ? "Generate New Code" : "Generate Emergency Code")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.purple)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isSending)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            Label("Emergency Bypass Code", systemImage: "key.fill")
        } footer: {
            Text("Give the child this code for emergencies. It unlocks the device for the selected duration and is one-time use only.")
        }
    }

    private var formattedCode: String {
        guard generatedCode.count == 6 else { return generatedCode }
        return "\(generatedCode.prefix(3)) \(generatedCode.suffix(3))"
    }

    private var durationLabel: String {
        durations.first { $0.0 == selectedDuration }?.1 ?? "\(selectedDuration) min"
    }
}

// MARK: - AppsTab helpers

extension AppsTab {
    func searchApps() async {
        let query = appSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        searchResults = []
        searchFocused = false

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=software&limit=20&country=us") else {
            isSearching = false; return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            searchError = "Search failed. Check your connection."
            isSearching = false; return
        }

        searchResults = results.compactMap { item in
            guard let trackId = item["trackId"] as? Int,
                  let name = item["trackName"] as? String else { return nil }
            return AppSearchResult(
                id: String(trackId),
                name: name,
                iconURL: item["artworkUrl100"] as? String ?? "",
                category: item["primaryGenreName"] as? String ?? "",
                sellerName: item["sellerName"] as? String ?? ""
            )
        }

        if searchResults.isEmpty { searchError = "No apps found for \"\(query)\"." }
        isSearching = false
    }

    func pushApp(_ result: AppSearchResult) async {
        // Don't push duplicates
        guard !pendingApps.values.contains(where: { $0.appStoreID == result.id }) else { return }
        pushingAppID = result.id
        let token = await auth.freshToken() ?? ""
        let app = RecommendedApp(
            appStoreID: result.id,
            appName: result.name,
            iconURL: result.iconURL,
            category: result.category,
            sellerName: result.sellerName,
            timestamp: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let encoded = try? encoder.encode(app),
              let url = URL(string: "\(dbURL)/users/\(user.uid)/pendingApps.json?auth=\(token)") else {
            pushingAppID = nil; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)
        pushingAppID = nil
        await loadPendingApps()
    }

    func loadPendingApps() async {
        let token = await auth.freshToken() ?? ""
        guard let url = URL(string: "\(dbURL)/users/\(user.uid)/pendingApps.json?auth=\(token)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result: [String: RecommendedApp] = [:]
            for (key, val) in dict {
                if let d = try? JSONSerialization.data(withJSONObject: val),
                   let app = try? decoder.decode(RecommendedApp.self, from: d) {
                    result[key] = app
                }
            }
            pendingApps = result
        } else {
            pendingApps = [:]
        }
    }

    func removePendingApp(pushKey: String) async {
        let token = await auth.freshToken() ?? ""
        guard let url = URL(string: "\(dbURL)/users/\(user.uid)/pendingApps/\(pushKey).json?auth=\(token)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        pendingApps.removeValue(forKey: pushKey)
    }
}

// WebsiteTab has its own refresh for websiteSetupInfo
extension WebsiteTab {
    func refreshSetupInfo() async {
        let token = await auth.freshToken() ?? ""
        await vm.loadWebsiteSetup(uid: user.uid, idToken: token)
    }
}

// MARK: - Commands Tab

struct CommandsTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var notifTitle = ""
    @State private var notifBody = ""
    @State private var isSendingNotif = false
    @State private var notifSent = false
    @FocusState private var notifBodyFocused: Bool

    var body: some View {
        List {
            // Send Notification
            Section {
                TextField("Title (optional)", text: $notifTitle)
                    .autocorrectionDisabled()
                TextField("Message", text: $notifBody)
                    .focused($notifBodyFocused)

                Button {
                    Task { await sendNotification() }
                } label: {
                    HStack {
                        if isSendingNotif {
                            ProgressView().tint(.white)
                        } else if notifSent {
                            Image(systemName: "checkmark.circle.fill")
                        } else {
                            Image(systemName: "bell.badge.fill")
                        }
                        Text(notifSent ? "Sent!" : "Send Notification")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(notifSent ? Color.green : Color.indigo)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(notifBody.trimmingCharacters(in: .whitespaces).isEmpty || isSendingNotif)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .animation(.easeInOut(duration: 0.2), value: notifSent)
            } header: {
                Text("Send Notification")
            } footer: {
                Text("The device will receive this as a push notification within 10 seconds.")
            }

            Section("Instant Commands") {
                CommandRow(icon: "lock.fill", label: "Lock All Apps Now", color: .red) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        await vm.sendCommand(.lockDevice, uid: user.uid, idToken: token)
                        vm.config.isLocked = true
                        vm.savedSection = "lock"
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        vm.savedSection = nil
                    }
                }
                CommandRow(icon: "lock.open.fill", label: "Unlock All Apps Now", color: .green) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        await vm.sendCommand(.unlockAll, uid: user.uid, idToken: token)
                        vm.config.isLocked = false
                        vm.savedSection = "unlock"
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        vm.savedSection = nil
                    }
                }
                CommandRow(icon: "arrow.triangle.2.circlepath", label: "Refresh Device Settings", color: .blue) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        await vm.sendCommand(.refreshSettings, uid: user.uid, idToken: token)
                        vm.savedSection = "refresh"
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        vm.savedSection = nil
                    }
                }
            }

            Section("Remove All Restrictions") {
                CommandRow(icon: "xmark.shield.fill", label: "Clear Everything & Unlock", color: .orange) {
                    Task {
                        // Reset config to defaults
                        vm.config.isLocked = false
                        vm.config.blockNewApps = false
                        vm.config.blockedWebsites = []
                        vm.config.allowedWebsites = []
                        vm.config.websiteFilterMode = .blacklist
                        vm.config.downtimeEnabled = false
                        vm.clearAppSelection()
                        // Save to Firebase and unlock device
                        let token = await auth.freshToken() ?? ""
                        await vm.saveAndSendCommand(.unlockAll, uid: user.uid, idToken: token, section: "clearall")
                    }
                }
            }

            if let section = vm.savedSection {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(section == "refresh" ? "Refresh sent" :
                             section == "lock" ? "Device locked" :
                             section == "unlock" ? "Device unlocked" : "Command sent")
                            .foregroundStyle(.green)
                    }
                }
            }

            EmergencyBypassSection(vm: vm, user: user)

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("About Commands", systemImage: "info.circle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Instant commands take effect the next time the device checks in (up to 30 seconds). Use the Websites, Downtime, and Apps tabs to configure and save persistent settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - DNS Tab

struct DNSTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    let globalApiKey: String
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var selectedSection = 0  // 0=Logs, 1=Allow, 2=Block, 3=Safety
    @State private var logs: [DNSLogEntry] = []
    @State private var allowList: [DNSListEntry] = []
    @State private var blockList: [DNSListEntry] = []
    @State private var isLoading = false
    @State private var newAllowDomain = ""
    @State private var newBlockDomain = ""
    @State private var logFilter = ""
    @State private var isSavingSafety = false
    @State private var safetySaved = false
    @State private var autoRefreshTimer: Timer? = nil

    private var profileID: String { vm.config.nextDNSProfileID }
    private var effectiveApiKey: String { globalApiKey.isEmpty ? vm.config.nextDNSApiKey : globalApiKey }
    private var isConfigured: Bool { !profileID.isEmpty && !effectiveApiKey.isEmpty }

    var body: some View {
        if !isConfigured {
            VStack(spacing: 16) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                Text("NextDNS Not Configured")
                    .font(.headline)
                Text("Go to the Websites tab → DNS Filter and enter a Profile ID and API Key to enable DNS logs and filtering.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Go to DNS Settings") { /* handled by tab switch */ }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0, green: 0.4, blue: 0.15))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 0) {
                // Segmented: Logs | Allow | Block | Safety
                Picker("DNS Section", selection: $selectedSection) {
                    Text("Logs").tag(0)
                    Text("Allow").tag(1)
                    Text("Block").tag(2)
                    Text("Safety").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 10)

                if isLoading && selectedSection != 3 {
                    Spacer(); ProgressView("Loading…"); Spacer()
                } else {
                    switch selectedSection {
                    case 0: logsView
                    case 1: listView(entries: allowList, endpoint: "allowlist", newDomain: $newAllowDomain, color: .green, label: "Allowed")
                    case 3: safetyView
                    default: listView(entries: blockList, endpoint: "denylist",  newDomain: $newBlockDomain, color: .red,   label: "Blocked")
                    }
                }
            }
            .task {
                await reload()
                startAutoRefresh()
            }
            .onChange(of: selectedSection) { _ in
                if selectedSection != 3 { Task { await reload() } }
            }
            .onDisappear { stopAutoRefresh() }
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        guard isConfigured else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                if selectedSection != 3 { await reload() }
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    // MARK: Logs View

    private var logsView: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by domain", text: $logFilter)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if !logFilter.isEmpty {
                    Button { logFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal).padding(.bottom, 8)

            let filtered = logFilter.isEmpty ? logs : logs.filter { $0.domain.localizedCaseInsensitiveContains(logFilter) }

            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(logs.isEmpty ? "No logs yet" : "No matches for \"\(logFilter)\"")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.blocked ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(entry.blocked ? .red : .green)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.domain)
                                    .font(.subheadline).fontWeight(.medium).lineLimit(1)
                                HStack(spacing: 6) {
                                    if !entry.deviceName.isEmpty {
                                        Text(entry.deviceName).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if !entry.reason.isEmpty {
                                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                                        Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Text(entry.timestamp.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        // Long-press to add to allow/block
                        .contextMenu {
                            Button {
                                Task { try? await NextDNSService.shared.addDomain(entry.domain, to: "allowlist", profileID: profileID, apiKey: effectiveApiKey) }
                            } label: { Label("Add to Allow List", systemImage: "checkmark.circle") }
                            Button(role: .destructive) {
                                Task { try? await NextDNSService.shared.addDomain(entry.domain, to: "denylist", profileID: profileID, apiKey: effectiveApiKey) }
                            } label: { Label("Add to Block List", systemImage: "xmark.circle") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: Allow / Block List View

    private func listView(entries: [DNSListEntry], endpoint: String,
                          newDomain: Binding<String>, color: Color, label: String) -> some View {
        List {
            Section {
                HStack {
                    TextField("domain (e.g. tiktok.com)", text: newDomain)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                    Button("Add") {
                        let d = newDomain.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !d.isEmpty else { return }
                        newDomain.wrappedValue = ""
                        Task {
                            try? await NextDNSService.shared.addDomain(d, to: endpoint, profileID: profileID, apiKey: effectiveApiKey)
                            await reload()
                        }
                    }
                    .disabled(newDomain.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(color)
                }
            } header: { Text("Add to \(label) List") }

            if entries.isEmpty {
                Section {
                    Text("No entries yet. Add a domain above.")
                        .foregroundStyle(.secondary).font(.subheadline)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: color == .green ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(color)
                            Text(entry.id).font(.subheadline)
                            if !entry.active { Text("(inactive)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { indices in
                        let toDelete = indices.map { entries[$0].id }
                        Task {
                            for d in toDelete {
                                try? await NextDNSService.shared.removeDomain(d, from: endpoint, profileID: profileID, apiKey: effectiveApiKey)
                            }
                            await reload()
                        }
                    }
                } header: {
                    Text("\(label) List (\(entries.count))")
                }
            }
        }
    }

    // MARK: Load

    private func reload() async {
        guard isConfigured else { return }
        isLoading = true
        async let l = NextDNSService.shared.fetchLogs(profileID: profileID, apiKey: effectiveApiKey)
        async let a = NextDNSService.shared.fetchList("allowlist", profileID: profileID, apiKey: effectiveApiKey)
        async let b = NextDNSService.shared.fetchList("denylist",  profileID: profileID, apiKey: effectiveApiKey)
        (logs, allowList, blockList) = await (l, a, b)
        isLoading = false
    }

    // MARK: - Safety View

    private var safetyView: some View {
        List {
            if !vm.config.forceDNS {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Enable \"Force NextDNS\" in the Websites tab → DNS Filter for safety settings to take effect.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { vm.config.safeSearchEnabled }, set: { vm.config.safeSearchEnabled = $0 })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Force SafeSearch")
                            Text("Google, Bing + DuckDuckGo show only filtered results")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "magnifyingglass.circle.fill").foregroundStyle(.blue) }
                }
                Toggle(isOn: Binding(get: { vm.config.youtubeRestrictedEnabled }, set: { vm.config.youtubeRestrictedEnabled = $0 })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube Restricted Mode")
                            Text("Hides explicit content in YouTube app and Safari")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "play.rectangle.fill").foregroundStyle(.red) }
                }
            } header: { Text("Search & Video") }

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(PCItem.knownServices) { item in
                        BlockChip(item: item, isBlocked: vm.config.blockedDNSServices.contains(item.id)) {
                            toggleDNSService(item.id)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: { Text("Block Apps") }
              footer: { Text("Blocks these apps system-wide via DNS — affects all browsers and native apps.") }

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(PCItem.knownCategories) { item in
                        BlockChip(item: item, isBlocked: vm.config.blockedDNSCategories.contains(item.id)) {
                            toggleDNSCategory(item.id)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: { Text("Block Categories") }
              footer: { Text("Blocks entire categories of content via NextDNS — more comprehensive than individual domains.") }

            Section {
                Button {
                    Task {
                        isSavingSafety = true
                        let token = await auth.freshToken() ?? ""
                        await vm.saveAndSendCommand(.updateWebsites, uid: user.uid, idToken: token, section: "websites")
                        await NextDNSService.shared.applyParentalControl(
                            profileID: profileID,
                            apiKey: effectiveApiKey,
                            safeSearch: vm.config.safeSearchEnabled,
                            youtubeRestricted: vm.config.youtubeRestrictedEnabled,
                            blockedServices: vm.config.blockedDNSServices,
                            blockedCategories: vm.config.blockedDNSCategories
                        )
                        isSavingSafety = false
                        safetySaved = true
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        safetySaved = false
                    }
                } label: {
                    HStack {
                        if isSavingSafety { ProgressView().tint(.white) }
                        else { Image(systemName: safetySaved ? "checkmark.circle.fill" : "network.badge.shield.half.filled") }
                        Text(safetySaved ? "Applied!" : (isSavingSafety ? "Applying..." : "Apply Safety Settings"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(safetySaved ? Color.green : Color(red: 0, green: 0.4, blue: 0.15))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isSavingSafety || !isConfigured)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            } footer: {
                Text("Updates your NextDNS profile immediately. All devices using this profile are affected.")
            }
        }
    }

    private func toggleDNSService(_ id: String) {
        if vm.config.blockedDNSServices.contains(id) {
            vm.config.blockedDNSServices.removeAll { $0 == id }
        } else {
            vm.config.blockedDNSServices.append(id)
        }
    }

    private func toggleDNSCategory(_ id: String) {
        if vm.config.blockedDNSCategories.contains(id) {
            vm.config.blockedDNSCategories.removeAll { $0 == id }
        } else {
            vm.config.blockedDNSCategories.append(id)
        }
    }
}

// MARK: - Shared Components

// MARK: - Block Chip (used in DNSTab Safety view)

struct BlockChip: View {
    let item: PCItem
    let isBlocked: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: item.icon).font(.caption2)
                Text(item.label).font(.caption).fontWeight(.medium).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isBlocked ? Color.red.opacity(0.12) : Color(.systemGray6),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isBlocked ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1))
            .foregroundStyle(isBlocked ? .red : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NextDNS Sync Status Row

struct NextDNSSyncStatusRow: View {
    @ObservedObject var vm: AdminUserViewModel
    var globalApiKey: String = ""
    @State private var profileName: String? = nil
    @State private var isChecking = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("NextDNS connected")
                    .font(.caption).fontWeight(.semibold)
                if let name = profileName {
                    Text("Profile: \(name)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if isChecking {
                    Text("Verifying...")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isChecking { ProgressView().scaleEffect(0.7) }
        }
        .task {
            isChecking = true
            profileName = await NextDNSService.shared.fetchProfileName(
                profileID: vm.config.nextDNSProfileID,
                apiKey: globalApiKey.isEmpty ? vm.config.nextDNSApiKey : globalApiKey
            )
            isChecking = false
        }
    }
}

struct ApplyButton: View {
    let label: String
    let icon: String
    let color: Color
    let section: String
    @ObservedObject var vm: AdminUserViewModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if vm.isSaving && vm.savedSection == nil {
                    ProgressView().tint(.white)
                } else if vm.savedSection == section {
                    Image(systemName: "checkmark.circle.fill")
                } else {
                    Image(systemName: icon)
                }
                Text(vm.savedSection == section ? "Applied!" : label)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(vm.savedSection == section ? Color.green : color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(vm.isSaving)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .animation(.easeInOut(duration: 0.2), value: vm.savedSection)
    }
}

struct CommandRow: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Helpers

private func relativeLastSeen(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return "Offline" }
    let mins = Int(-date.timeIntervalSinceNow / 60)
    if mins < 2  { return "Just now" }
    if mins < 60 { return "\(mins)m ago" }
    let hrs = mins / 60
    if hrs < 24  { return "\(hrs)h ago" }
    return "\(hrs / 24)d ago"
}

// MARK: - Models

struct ManagedUser: Identifiable {
    let uid: String
    let email: String
    let displayName: String
    let deviceName: String
    let isOnline: Bool
    let lastSeen: String
    var id: String { uid }

    var primaryLabel: String { displayName.isEmpty ? email : displayName }
    var secondaryLabel: String { displayName.isEmpty ? deviceName : email }
}
