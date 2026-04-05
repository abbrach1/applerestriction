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
                    deviceName: info["deviceName"] as? String ?? "Unknown Device",
                    isOnline: info["isOnline"] as? Bool ?? false,
                    lastSeen: info["lastSeen"] as? String ?? ""
                )
            }.sorted { $0.email < $1.email }
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

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading users...")
                } else if vm.users.isEmpty {
                    ContentUnavailableView(
                        "No Users Yet",
                        systemImage: "person.2.slash",
                        description: Text("Add users in Firebase Console under Authentication.")
                    )
                } else {
                    List(vm.users) { user in
                        NavigationLink {
                            AdminUserControlView(user: user)
                                .environmentObject(auth)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(user.isOnline ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.email)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(user.deviceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if user.isOnline {
                                    Text("Online")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Managed Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            let token = await auth.freshToken() ?? ""
                            await vm.loadUsers(idToken: token)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                }
            }
            .task {
                let token = await auth.freshToken() ?? ""
                await vm.loadUsers(idToken: token)
            }
        }
    }
}

// MARK: - Admin User Control View (Full Settings Editor)

struct AdminUserControlView: View {
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @StateObject private var vm = AdminUserViewModel()
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // User header
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.email)
                        .font(.subheadline).fontWeight(.medium)
                    Text(user.deviceName)
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

            // Tab picker
            Picker("Section", selection: $selectedTab) {
                Label("Websites", systemImage: "globe").tag(0)
                Label("Downtime", systemImage: "moon.fill").tag(1)
                Label("Apps", systemImage: "square.grid.2x2.fill").tag(2)
                Label("Commands", systemImage: "bolt.fill").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if vm.isLoading {
                Spacer()
                ProgressView("Loading settings...")
                Spacer()
            } else {
                TabView(selection: $selectedTab) {
                    WebsiteTab(vm: vm, user: user)
                        .tag(0)
                    DowntimeTab(vm: vm, user: user)
                        .tag(1)
                    AppsTab(vm: vm, user: user)
                        .tag(2)
                    CommandsTab(vm: vm, user: user)
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle(user.email.components(separatedBy: "@").first ?? user.email)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let token = await auth.freshToken() ?? ""
            await vm.load(uid: user.uid, idToken: token)
        }
    }
}

// MARK: - Website Tab

struct WebsiteTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @State private var newDomain = ""
    @State private var newPendingDomain = ""
    @State private var isSendingDomain = false
    @State private var pendingWebsites: [String: String] = [:]  // [pushKey: domain]
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

            // Send a specific website to the child's device
            Section {
                HStack {
                    TextField("domain (e.g. amazon.com)", text: $newPendingDomain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button {
                        Task { await sendWebsiteToDevice() }
                    } label: {
                        if isSendingDomain { ProgressView() }
                        else { Text("Send") }
                    }
                    .disabled(newPendingDomain.trimmingCharacters(in: .whitespaces).isEmpty || isSendingDomain)
                }

                if !pendingWebsites.isEmpty {
                    ForEach(Array(pendingWebsites), id: \.key) { pushKey, domain in
                        HStack {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                            Text(domain).font(.subheadline)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task { await removePendingWebsite(pushKey: pushKey) }
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Send Website to Device")
            } footer: {
                Text("Type a domain and tap Send. The child will see it in B-SAFE and can add it to their whitelist with one tap.")
            }

            Section {
                Toggle(isOn: $vm.config.contentBlockerEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Safari Content Blocker")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Enforces website rules inside Safari using plain domain names")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "safari.fill").foregroundStyle(.blue)
                    }
                }

                Toggle(isOn: $vm.config.forceDNS) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Force CleanBrowsing DNS")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Blocks adult & malware domains system-wide (all apps, not just Safari)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.purple)
                    }
                }
            } header: {
                Text("Extra Protection")
            } footer: {
                Text("Content Blocker uses admin's allowed/blocked list in Safari. CleanBrowsing DNS works across all apps and can't be bypassed by switching browsers.")
                    .font(.caption)
            }

            Section {
                ApplyButton(label: "Apply Website Settings",
                            icon: "globe",
                            color: .blue,
                            section: "websites",
                            vm: vm) {
                    Task {
                        let token = await auth.freshToken() ?? ""
                        await vm.saveAndSendCommand(.updateWebsites, uid: user.uid, idToken: token, section: "websites")
                    }
                }
            }
        }
        .task { await loadPendingWebsites() }
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

    private func loadPendingWebsites() async {
        let token = await auth.freshToken() ?? ""
        guard let url = URL(string: "\(dbURL)/users/\(user.uid)/pendingWebsites.json?auth=\(token)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            pendingWebsites = dict
        }
    }

    private func sendWebsiteToDevice() async {
        let domain = cleanDomain(newPendingDomain)
        guard !domain.isEmpty else { return }
        isSendingDomain = true
        let token = await auth.freshToken() ?? ""
        guard let url = URL(string: "\(dbURL)/users/\(user.uid)/pendingWebsites.json?auth=\(token)"),
              let body = try? JSONEncoder().encode(domain) else {
            isSendingDomain = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
        newPendingDomain = ""
        isSendingDomain = false
        await loadPendingWebsites()
    }

    private func removePendingWebsite(pushKey: String) async {
        let token = await auth.freshToken() ?? ""
        guard let url = URL(string: "\(dbURL)/users/\(user.uid)/pendingWebsites/\(pushKey).json?auth=\(token)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        pendingWebsites.removeValue(forKey: pushKey)
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

struct AppsTab: View {
    @ObservedObject var vm: AdminUserViewModel
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @State private var showingPicker = false

    var body: some View {
        List {
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

// MARK: - Shared Components

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

// MARK: - Models

struct ManagedUser: Identifiable {
    let uid: String
    let email: String
    let deviceName: String
    let isOnline: Bool
    let lastSeen: String
    var id: String { uid }
}
