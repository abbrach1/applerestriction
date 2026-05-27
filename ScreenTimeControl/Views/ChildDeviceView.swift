import SwiftUI
import UIKit
import StoreKit
import SafariServices

#if !targetEnvironment(simulator)
import FamilyControls
#endif

struct ChildDeviceView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @EnvironmentObject var authManager: ActiveAuthorizationManager
    @State private var isRefreshing = false
    @State private var showSendAppList = false
    @State private var isSendingList = false
    @State private var listSentMessage: String?
    @State private var contentBlockerEnabled: Bool = true
    @State private var showUnlockRequest = false
    @State private var unlockReason = ""
    @State private var showChecklist = false
    @State private var showWebsiteRequest = false
    @State private var websiteRequestDomain = ""
    @State private var websiteRequestReason = ""
    @State private var showBypassEntry = false
    @State private var bypassCode = ""
    @State private var showBypassResultAlert = false
    @State private var bypassSuccess = false
    @State private var showFilterLogs = false
    @State private var showAppRequest = false
    @State private var appRequestQuery = ""
    @State private var appRequestResults: [ChildAppSearchResult] = []
    @State private var appRequestIsSearching = false
    @State private var appRequestError: String?
    @State private var appRequestReason = ""
    @State private var appRequestSelected: ChildAppSearchResult?
    @State private var appRequestSending = false
    @State private var showMyApps = false
    #if !targetEnvironment(simulator)
    @StateObject private var captiveDetector = CaptivePortalDetector.shared
    @State private var myAppsSelection = FamilyActivitySelection()
    #endif
    #if !targetEnvironment(simulator)
    @State private var appListSelection = FamilyActivitySelection()
    #endif

    private let green = Color(red: 0, green: 0.4, blue: 0.15)

    var body: some View {
        let config = settingsManager.configuration
        TabView {
            mainTab(config: config)
                .tabItem { Label("Home", systemImage: "shield.checkered") }

            DeviceInfoTab()
                .tabItem { Label("Device", systemImage: "iphone") }

            if config.browserEnabled {
                SafeBrowserView()
                    .environmentObject(settingsManager)
                    .tabItem { Label("Browser", systemImage: "globe") }
            }
        }
        .tint(green)
    }

    @ViewBuilder
    private func mainTab(config: ScreenTimeConfiguration) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    syncStatusBar
                    statusCardGrid(config: config)
                    pendingSection(config: config)
                    actionSection
                    menuSection
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("B-SAFE")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showChecklist) {
                SetupChecklistView()
                    .environmentObject(auth)
                    .environmentObject(syncService)
                    .environmentObject(settingsManager)
                    .environmentObject(authManager)
            }
            .alert("Request Website Access", isPresented: $showWebsiteRequest) {
                TextField("Domain (e.g. youtube.com)", text: $websiteRequestDomain)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Reason (optional)", text: $websiteRequestReason).autocorrectionDisabled()
                Button("Send Request") {
                    let domain = websiteRequestDomain.trimmingCharacters(in: .whitespaces)
                    let reason = websiteRequestReason.trimmingCharacters(in: .whitespaces)
                    guard !domain.isEmpty else { return }
                    Task { await syncService.sendWebsiteRequest(domain: domain, reason: reason) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your admin will be notified and can approve or deny.") }
            .alert("Request Unlock", isPresented: $showUnlockRequest) {
                TextField("Reason (optional)", text: $unlockReason).autocorrectionDisabled()
                Button("Send Request") {
                    let r = unlockReason.trimmingCharacters(in: .whitespaces)
                    Task { await syncService.sendUnlockRequest(reason: r) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your admin will receive a notification and can approve or deny.") }
            .alert("Emergency Code", isPresented: $showBypassEntry) {
                TextField("6-digit code", text: $bypassCode)
                    .keyboardType(.numberPad).autocorrectionDisabled()
                Button("Unlock") {
                    Task {
                        let ok = await syncService.redeemBypassCode(
                            bypassCode.trimmingCharacters(in: .whitespaces))
                        bypassSuccess = ok
                        showBypassResultAlert = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Enter the emergency code your admin gave you.") }
            .alert(bypassSuccess ? "Unlocked!" : "Invalid Code",
                   isPresented: $showBypassResultAlert) {
                Button("OK") {}
            } message: {
                Text(bypassSuccess
                     ? "Device is now unlocked for the permitted duration."
                     : "That code is invalid or already used. Ask your admin for a new one.")
            }
            .task {
                await checkContentBlockerState()
                updateInstallationBlock()
                #if !targetEnvironment(simulator)
                captiveDetector.start()
                #endif
            }
            #if !targetEnvironment(simulator)
            .sheet(isPresented: $captiveDetector.showPrompt) {
                CaptivePortalSheet(
                    onOpen: { captiveDetector.openCaptivePortal() },
                    onDismiss: { captiveDetector.showPrompt = false }
                )
            }
            .sheet(isPresented: $showMyApps) {
                MyAppsSheet(
                    initialSelection: $myAppsSelection,
                    existing: syncService.installedApps,
                    onSubmit: { entries in
                        Task {
                            for (name, base64, isCat) in entries {
                                await syncService.submitInstalledApp(
                                    name: name,
                                    selectionData: base64,
                                    isCategory: isCat
                                )
                            }
                            showMyApps = false
                        }
                    },
                    onRemove: { key in
                        Task { await syncService.removeInstalledApp(key: key) }
                    },
                    onClose: { showMyApps = false }
                )
                .environmentObject(syncService)
            }
            #endif
            .onChange(of: syncService.pendingApps.count) {
                updateInstallationBlock()
            }
            .sheet(isPresented: $showAppRequest) {
                AppRequestSheet(
                    query: $appRequestQuery,
                    results: $appRequestResults,
                    isSearching: $appRequestIsSearching,
                    error: $appRequestError,
                    selected: $appRequestSelected,
                    reason: $appRequestReason,
                    isSending: $appRequestSending,
                    onSearch: searchAppsForRequest,
                    onSend: sendAppRequest,
                    onClose: { showAppRequest = false }
                )
                .environmentObject(syncService)
            }
            #if !targetEnvironment(simulator)
            .sheet(isPresented: $showSendAppList) {
                NavigationStack {
                    VStack(spacing: 0) {
                        Text("Select all the apps you have installed. Admin will review and approve your list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        FamilyActivityPicker(selection: $appListSelection)
                    }
                    .navigationTitle("My Apps")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showSendAppList = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                Task {
                                    showSendAppList = false
                                    isSendingList = true
                                    await uploadAppList()
                                    isSendingList = false
                                }
                            } label: {
                                if isSendingList { ProgressView() }
                                else { Text("Send") }
                            }
                        }
                    }
                }
            }
            #endif
        } // end NavigationStack
    } // end mainTab

    // MARK: - Sub-views

    @ViewBuilder private var heroCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [green, green.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.2)).frame(width: 52, height: 52)
                    Text(initials).font(.title3).fontWeight(.bold).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayedName).font(.headline).foregroundStyle(.white)
                    Text(UIDevice.current.name).font(.caption).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 4) {
                        Circle().fill(.white.opacity(0.9)).frame(width: 5, height: 5)
                        Text("Protected by B-SAFE").font(.caption2).foregroundStyle(.white.opacity(0.9))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Circle().fill(syncService.isOnline ? Color.green : Color.gray).frame(width: 10, height: 10)
                    Text(syncService.isOnline ? "Online" : "Offline")
                        .font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(16)
        }
        .padding(.horizontal)
    }

    @ViewBuilder private var syncStatusBar: some View {
        HStack(spacing: 10) {
            if !syncService.isOnline {
                Image(systemName: "wifi.slash").foregroundStyle(.orange).font(.caption)
                Text("Offline — restrictions remain active").font(.caption).foregroundStyle(.secondary)
            } else if let err = syncService.syncError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.caption)
                Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let last = syncService.lastSyncDate {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(green).font(.caption)
                Text("Synced \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).font(.caption)
                Text("Not yet synced").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { isRefreshing = true; await syncService.manualSync(); isRefreshing = false }
            } label: {
                Group {
                    if isRefreshing { ProgressView().scaleEffect(0.7) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 28, height: 28)
                .background(green.opacity(0.1), in: Circle())
                .foregroundStyle(green)
            }
            .disabled(isRefreshing || !syncService.isOnline)
        }
        .padding(.horizontal)
    }

    @ViewBuilder private func statusCardGrid(config: ScreenTimeConfiguration) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 12) {
            StatusCard(icon: "lock.fill", value: config.isLocked ? "LOCKED" : "Off",
                       label: "Device Lock", active: config.isLocked, color: .red)
            StatusCard(icon: "globe", value: websiteFilterStatus(config),
                       label: "Web Filter", active: isWebsiteFilterActive(config), color: .blue)
            StatusCard(icon: "network.badge.shield.half.filled", value: config.forceDNS ? "On" : "Off",
                       label: "DNS Filter", active: config.forceDNS, color: .purple)
            StatusCard(icon: "square.grid.2x2.fill", value: appBlockingStatus(config),
                       label: "App Blocking", active: isAppBlockingActive(config), color: .orange)
            StatusCard(icon: "moon.fill", value: downtimeStatus(config),
                       label: "Downtime", active: config.downtimeEnabled, color: .indigo)
            StatusCard(icon: "xmark.app.fill", value: config.blockNewApps ? "On" : "Off",
                       label: "Block Installs", active: config.blockNewApps, color: .orange)
        }
        .padding(.horizontal)
    }

    @ViewBuilder private func pendingSection(config: ScreenTimeConfiguration) -> some View {
        if syncService.dnsProtectionMissing && config.forceDNS {
            HStack(spacing: 12) {
                Image(systemName: "network.slash").font(.title3).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DNS Protection Disabled").font(.subheadline).fontWeight(.semibold).foregroundStyle(.white)
                    Text("Go to Settings → General → VPN & Device Management → B-SAFE DNS → Install").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button("Restore") {
                    Task {
                        #if !targetEnvironment(simulator)
                        await ContentBlockerService.shared.enableForcedDNS(profileID: config.nextDNSProfileID, removalPassword: config.dnsRemovalPassword)
                        let ok = await ContentBlockerService.shared.isDNSEnabled()
                        await MainActor.run { syncService.dnsProtectionMissing = !ok }
                        if ok { syncService.cancelDNSTamperAlerts() }
                        #endif
                    }
                }
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            .padding()
            .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
        if config.websiteFilterMode == .whitelist && !contentBlockerEnabled {
            warningBanner(icon: "exclamationmark.shield.fill", color: .red,
                          title: "Website filter not active",
                          detail: "Go to Settings → Safari → Extensions → enable B-SAFE Content Blocker")
        }
        if !syncService.pendingWebsites.isEmpty {
            let websiteItems = Array(syncService.pendingWebsites)
            pendingCard(header: "Websites from Admin", icon: "globe.badge.exclamationmark") {
                ForEach(websiteItems, id: \.key) { item in
                    PendingWebsiteRow(pushKey: item.key, domain: item.value)
                        .environmentObject(auth).environmentObject(syncService).environmentObject(settingsManager)
                    if item.key != websiteItems.last?.key { Divider() }
                }
            }
        }
        if !syncService.pendingApps.isEmpty {
            let appItems = Array(syncService.pendingApps)
            pendingCard(header: "Apps from Admin", icon: "arrow.down.app.fill") {
                ForEach(appItems, id: \.key) { item in
                    PendingAppRow(pushKey: item.key, app: item.value).environmentObject(syncService)
                    if item.key != appItems.last?.key { Divider() }
                }
            }
        }
        if !syncService.pendingWebsiteRequests.isEmpty {
            pendingCard(header: "Your Website Requests", icon: "clock.badge.exclamationmark") {
                ForEach(syncService.pendingWebsiteRequests, id: \.key) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.request.domain).font(.subheadline).fontWeight(.medium)
                            Text("Pending admin approval").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { Task { await syncService.cancelWebsiteRequest(key: item.key) } }
                            .font(.caption).foregroundStyle(.red)
                    }
                    .padding(.vertical, 2)
                    if item.key != syncService.pendingWebsiteRequests.last?.key { Divider() }
                }
            }
        }
        if !syncService.pendingAppRequests.isEmpty {
            pendingCard(header: "Your App Requests", icon: "arrow.down.app") {
                ForEach(syncService.pendingAppRequests, id: \.key) { item in
                    HStack(spacing: 10) {
                        AsyncImage(url: URL(string: item.request.iconURL)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.request.appName).font(.subheadline).fontWeight(.medium).lineLimit(1)
                            Text("Pending admin approval").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { Task { await syncService.cancelAppRequest(key: item.key) } }
                            .font(.caption).foregroundStyle(.red)
                    }
                    .padding(.vertical, 2)
                    if item.key != syncService.pendingAppRequests.last?.key { Divider() }
                }
            }
        }
        if syncService.pendingUnlockRequest != nil {
            pendingCard(header: "Unlock Request", icon: "lock.open.fill") {
                HStack(spacing: 12) {
                    ProgressView().tint(green)
                    Text("Waiting for admin approval").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button("Cancel") { Task { await syncService.cancelUnlockRequest() } }
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var actionSection: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 12) {
            ChildActionButton(icon: "arrow.clockwise", label: "Sync Now", color: green) {
                Task { isRefreshing = true; await syncService.manualSync(); isRefreshing = false }
            }
            ChildActionButton(icon: "lock.open.fill", label: "Request Unlock", color: .orange) {
                unlockReason = ""; showUnlockRequest = true
            }
            ChildActionButton(icon: "globe.badge.exclamationmark", label: "Request Website", color: .blue) {
                websiteRequestDomain = ""; websiteRequestReason = ""; showWebsiteRequest = true
            }
            ChildActionButton(icon: "square.and.arrow.up", label: "Send App List", color: .teal) {
                showSendAppList = true
            }
            ChildActionButton(icon: "arrow.down.app.fill", label: "Request App", color: .purple) {
                appRequestQuery = ""
                appRequestResults = []
                appRequestSelected = nil
                appRequestReason = ""
                appRequestError = nil
                showAppRequest = true
            }
            ChildActionButton(icon: "square.grid.3x3.fill", label: "My Apps", color: .indigo) {
                #if !targetEnvironment(simulator)
                myAppsSelection = FamilyActivitySelection()
                #endif
                showMyApps = true
            }
        }
        .padding(.horizontal)
        if let msg = listSentMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(msg).font(.caption).foregroundStyle(.green)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private var menuSection: some View {
        VStack(spacing: 0) {
            menuRow(icon: "key.fill", label: "Enter Emergency Code", color: .purple) {
                bypassCode = ""; showBypassEntry = true
            }
            Divider().padding(.leading, 52)
            menuRow(icon: "checklist", label: "Setup Checklist", color: green) {
                showChecklist = true
            }
            Divider().padding(.leading, 52)
            Divider().padding(.leading, 52)
            menuRow(icon: "line.3.horizontal.decrease.circle", label: "Filter Logs", color: .indigo) {
                showFilterLogs = true
            }
            Divider().padding(.leading, 52)
            menuRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out", color: .red) {
                auth.signOut()
            }
        }
        .sheet(isPresented: $showFilterLogs) {
            FilterLogsView()
                .environmentObject(auth)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    private func uploadAppList() async {
        #if !targetEnvironment(simulator)
        guard let user = auth.currentUser else { return }
        let token = await auth.freshToken() ?? user.idToken

        let report = AppListReport(
            selectionData: (try? JSONEncoder().encode(appListSelection))?.base64EncodedString() ?? "",
            appCount: appListSelection.applicationTokens.count,
            categoryCount: appListSelection.categoryTokens.count,
            timestamp: Date(),
            reviewed: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let encoded = try? encoder.encode(report),
              let url = URL(string: "https://applerestrictions-default-rtdb.firebaseio.com/users/\(user.uid)/appList.json?auth=\(token)") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)

        listSentMessage = "App list sent! (\(report.appCount) apps, \(report.categoryCount) categories)"
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        listSentMessage = nil
        #endif
    }

    // MARK: - Helpers

    /// Check if BSAFEContentBlocker is enabled in Safari settings.
    private func checkContentBlockerState() async {
        #if !targetEnvironment(simulator)
        let id = "com.abbrachfeld.screentimecontrolabbrach.BSAFEContentBlocker"
        if let state = try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: id) {
            contentBlockerEnabled = state.isEnabled
        }
        #endif
    }

    /// When admin has pushed apps, temporarily lift the install block so they can be installed.
    /// Re-enables once the pending list is cleared.
    private func updateInstallationBlock() {
        #if !targetEnvironment(simulator)
        settingsManager.updateInstallationBlock(hasPendingAdminApps: !syncService.pendingApps.isEmpty)
        #endif
    }

    // MARK: - App Request

    private func searchAppsForRequest() async {
        let query = appRequestQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        appRequestIsSearching = true
        appRequestError = nil
        appRequestResults = []

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=software&limit=20&country=us") else {
            appRequestIsSearching = false; return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            appRequestError = "Search failed. Check your connection."
            appRequestIsSearching = false; return
        }

        appRequestResults = results.compactMap { item in
            guard let trackId = item["trackId"] as? Int,
                  let name = item["trackName"] as? String else { return nil }
            return ChildAppSearchResult(
                id: String(trackId),
                name: name,
                iconURL: item["artworkUrl100"] as? String ?? "",
                category: item["primaryGenreName"] as? String ?? "",
                sellerName: item["sellerName"] as? String ?? ""
            )
        }
        if appRequestResults.isEmpty { appRequestError = "No apps found for \"\(query)\"." }
        appRequestIsSearching = false
    }

    private func sendAppRequest() async {
        guard let app = appRequestSelected else { return }
        appRequestSending = true
        await syncService.sendAppRequest(
            appStoreID: app.id,
            appName:    app.name,
            iconURL:    app.iconURL,
            category:   app.category,
            sellerName: app.sellerName,
            reason:     appRequestReason.trimmingCharacters(in: .whitespaces)
        )
        appRequestSending = false
        showAppRequest = false
    }

    private func isWebsiteFilterActive(_ config: ScreenTimeConfiguration) -> Bool {
        config.websiteFilterMode == .whitelist || !config.blockedWebsites.isEmpty
    }

    private func websiteFilterStatus(_ config: ScreenTimeConfiguration) -> String {
        if config.websiteFilterMode == .whitelist {
            let adminCount = config.allowedWebsites.count
            if adminCount > 0 {
                return "Whitelist (\(adminCount) site\(adminCount == 1 ? "" : "s"))"
            }
            let localCount = localWhitelistCount()
            return localCount > 0 ? "Whitelist (\(localCount) site\(localCount == 1 ? "" : "s"))" : "Whitelist active"
        }
        if config.blockedWebsites.isEmpty { return "Off" }
        return "Blocking \(config.blockedWebsites.count) site\(config.blockedWebsites.count == 1 ? "" : "s")"
    }

    private func localWhitelistCount() -> Int {
        #if targetEnvironment(simulator)
        return 0
        #else
        guard let base64 = UserDefaults.standard.string(forKey: "screentime.websiteSelection"),
              let data = Data(base64Encoded: base64),
              let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return 0 }
        return sel.webDomainTokens.count + sel.categoryTokens.count
        #endif
    }

    private func isAppBlockingActive(_ config: ScreenTimeConfiguration) -> Bool {
        config.isLocked || config.blockedAppsSelectionData != nil
    }

    private func appBlockingStatus(_ config: ScreenTimeConfiguration) -> String {
        if config.isLocked { return "All blocked" }
        guard config.blockedAppsSelectionData != nil else { return "Off" }
        return "Selected apps blocked"
    }

    private func downtimeStatus(_ config: ScreenTimeConfiguration) -> String {
        guard config.downtimeEnabled else { return "Off" }
        let s = config.downtimeSchedule
        func fmt(_ h: Int, _ m: Int) -> String {
            let suffix = h >= 12 ? "PM" : "AM"
            let hr = h == 0 ? 12 : (h > 12 ? h - 12 : h)
            return String(format: "%d:%02d %@", hr, m, suffix)
        }
        return "\(fmt(s.startHour, s.startMinute)) – \(fmt(s.endHour, s.endMinute))"
    }

    private var displayedName: String {
        syncService.displayName.isEmpty ? (auth.currentUser?.email ?? "B-SAFE User") : syncService.displayName
    }

    private var initials: String {
        let words = displayedName.split(separator: " ")
        if words.count >= 2 {
            return String((words[0].first ?? "?")).uppercased() + String((words[1].first ?? "?")).uppercased()
        }
        return String(displayedName.prefix(2)).uppercased()
    }

    @ViewBuilder
    private func warningBanner(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func pendingCard<Content: View>(header: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(green)
                Text(header).font(.caption).fontWeight(.semibold).foregroundStyle(green)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            content()
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func menuRow(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon).font(.subheadline).foregroundStyle(color)
                }
                Text(label).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status Card

struct StatusCard: View {
    let icon: String
    let value: String
    let label: String
    let active: Bool
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(active ? color : .secondary)
                Spacer()
                Circle()
                    .fill(active ? color : Color(.systemGray4))
                    .frame(width: 7, height: 7)
            }
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(active ? color.opacity(0.08) : Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(active ? color.opacity(0.2) : Color(.separator), lineWidth: 0.5))
    }
}

// MARK: - Child Action Button

struct ChildActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Device Info Tab

struct DeviceInfoTab: View {
    @State private var batteryLevel: Float = -1
    @State private var batteryState: UIDevice.BatteryState = .unknown
    @State private var storageTotal: Int64 = 0
    @State private var storageFree: Int64 = 0

    private let green = Color(red: 0, green: 0.4, blue: 0.15)

    var body: some View {
        NavigationStack {
            List {
                // Device identity
                Section("Device") {
                    LabeledContent("Name", value: UIDevice.current.name)
                    LabeledContent("Model", value: UIDevice.current.localizedModel)
                    LabeledContent("iOS Version", value: UIDevice.current.systemVersion)
                    LabeledContent("System", value: UIDevice.current.systemName)
                }

                // Battery
                Section {
                    if batteryLevel >= 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Battery")
                                Spacer()
                                Text(batteryStateLabel)
                                    .font(.caption)
                                    .foregroundStyle(batteryStateColor)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(batteryStateColor.opacity(0.12), in: Capsule())
                            }
                            ProgressView(value: Double(batteryLevel))
                                .tint(batteryColor)
                            Text("\(Int(batteryLevel * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Text("Battery")
                            Spacer()
                            Text("Unavailable").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                } header: { Text("Battery") }

                // Storage
                Section {
                    if storageTotal > 0 {
                        let used = storageTotal - storageFree
                        let fraction = Double(used) / Double(storageTotal)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Storage Used")
                                Spacer()
                                Text("\(formatBytes(used)) / \(formatBytes(storageTotal))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ProgressView(value: fraction)
                                .tint(fraction > 0.9 ? .red : fraction > 0.7 ? .orange : green)
                            Text("\(formatBytes(storageFree)) free")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Text("Storage")
                            Spacer()
                            Text("Unavailable").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                } header: { Text("Storage") }
            }
            .navigationTitle("My Device")
            .navigationBarTitleDisplayMode(.large)
            .task { loadDeviceInfo() }
        }
    }

    private func loadDeviceInfo() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            storageTotal = attrs[.systemSize] as? Int64 ?? 0
            storageFree  = attrs[.systemFreeSize] as? Int64 ?? 0
        }
    }

    private var batteryStateLabel: String {
        switch batteryState {
        case .charging:  return "Charging"
        case .full:      return "Full"
        case .unplugged: return "Unplugged"
        default:         return "Unknown"
        }
    }

    private var batteryStateColor: Color {
        switch batteryState {
        case .charging: return .orange
        case .full:     return green
        default:
            guard batteryLevel >= 0 else { return .secondary }
            return batteryLevel < 0.2 ? .red : batteryLevel < 0.4 ? .orange : green
        }
    }

    private var batteryColor: Color {
        guard batteryLevel >= 0 else { return green }
        return batteryLevel < 0.2 ? .red : batteryLevel < 0.4 ? .orange : green
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Admin Setup Sheet (runs on child device)

struct AdminSetupSheet: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @Environment(\.dismiss) var dismiss

    @State private var enteredPin = ""
    @State private var isUnlocked = false
    @State private var pinError = false
    @State private var showPicker = false
    @State private var isSaving = false
    @State private var savedMessage: String?

    #if !targetEnvironment(simulator)
    @State private var appSelection = FamilyActivitySelection()
    #endif

    // Admin PIN = first 6 chars of admin password hash, or use a fixed PIN for simplicity
    // We verify by checking if the entered value matches the admin's Firebase password
    // For simplicity, use a fixed 6-digit PIN stored in UserDefaults (set by admin)
    private let adminPin = "bsafe1"  // Admin can change this in future

    var body: some View {
        NavigationStack {
            if !isUnlocked {
                pinEntryView
            } else {
                setupView
            }
        }
    }

    var pinEntryView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
            Text("Admin Setup")
                .font(.title2).fontWeight(.bold)
            Text("Enter the admin PIN to configure app blocking on this device.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            SecureField("Admin PIN", text: $enteredPin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .multilineTextAlignment(.center)

            if pinError {
                Text("Incorrect PIN")
                    .foregroundStyle(.red).font(.caption)
            }

            Button("Unlock") {
                if enteredPin == adminPin {
                    isUnlocked = true
                    pinError = false
                    loadCurrentSelection()
                } else {
                    pinError = true
                    enteredPin = ""
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(enteredPin.isEmpty)

            Spacer()
        }
        .navigationTitle("Admin Access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    var setupView: some View {
        List {
            Section {
                #if targetEnvironment(simulator)
                Text("FamilyActivityPicker is not available on Simulator. Run on a real device.")
                    .foregroundStyle(.secondary).font(.caption)
                #else
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Image(systemName: "app.badge.checkmark").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Select Apps to Block")
                                .font(.subheadline).fontWeight(.medium).foregroundStyle(.primary)
                            Text(selectionSummary)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if hasSelection {
                    Button("Clear App Selection", role: .destructive) {
                        appSelection = FamilyActivitySelection()
                    }
                }
                #endif
            } header: {
                Text("App Blocking")
            } footer: {
                Text("Apps you select will show a blocking screen. All other apps remain accessible.")
            }

            if let msg = savedMessage {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(msg).foregroundStyle(.green)
                    }
                }
            }

            Section {
                Button {
                    Task { await saveSelection() }
                } label: {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        else { Image(systemName: "icloud.and.arrow.up") }
                        Text(isSaving ? "Saving..." : "Save & Apply")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 0, green: 0.4, blue: 0.15))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isSaving)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Admin Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #if !targetEnvironment(simulator)
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                FamilyActivityPicker(selection: $appSelection)
                    .navigationTitle("Select Apps to Block")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPicker = false }
                        }
                    }
            }
        }
        #endif
    }

    #if targetEnvironment(simulator)
    var hasSelection: Bool { false }
    var selectionSummary: String { "Requires real device" }
    #else
    var hasSelection: Bool {
        !appSelection.applicationTokens.isEmpty || !appSelection.categoryTokens.isEmpty
    }
    var selectionSummary: String {
        let apps = appSelection.applicationTokens.count
        let cats = appSelection.categoryTokens.count
        if apps == 0 && cats == 0 { return "No apps selected yet" }
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if cats > 0 { parts.append("\(cats) categor\(cats == 1 ? "y" : "ies")") }
        return parts.joined(separator: ", ") + " selected"
    }
    #endif

    private func loadCurrentSelection() {
        #if !targetEnvironment(simulator)
        guard let base64 = settingsManager.configuration.blockedAppsSelectionData,
              let data = Data(base64Encoded: base64),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return }
        appSelection = selection
        #endif
    }

    private func saveSelection() async {
        isSaving = true
        #if !targetEnvironment(simulator)
        // Serialize selection
        if let data = try? JSONEncoder().encode(appSelection) {
            settingsManager.configuration.blockedAppsSelectionData = data.base64EncodedString()
        } else {
            settingsManager.configuration.blockedAppsSelectionData = nil
        }
        // Apply immediately on this device
        settingsManager.selectedAppsToBlock = appSelection
        settingsManager.applyAppRestrictions()
        #endif

        // Sync config up to Firebase so admin can see it
        guard let user = auth.currentUser else { isSaving = false; return }
        let token = await auth.freshToken() ?? user.idToken
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let encoded = try? encoder.encode(settingsManager.configuration),
           let url = URL(string: "https://applerestrictions-default-rtdb.firebaseio.com/users/\(user.uid)/settings.json?auth=\(token)") {
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = encoded
            _ = try? await URLSession.shared.data(for: req)
        }

        isSaving = false
        savedMessage = "App restrictions saved and applied!"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        savedMessage = nil
    }
}

// MARK: - Website Setup Sheet (PIN-protected, runs on child device)

struct WebsiteSetupSheet: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @Environment(\.dismiss) var dismiss

    @State private var isUnlocked = false
    @State private var enteredPin = ""
    @State private var showPicker = false
    @State private var isSaving = false
    @State private var savedMessage: String?
    #if !targetEnvironment(simulator)
    @State private var webSelection = FamilyActivitySelection()
    #endif
    private let adminPin = "bsafe1"

    var body: some View {
        NavigationStack {
            if isUnlocked {
                unlockedView
            } else {
                pinEntryView
            }
        }
    }

    var pinEntryView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 60))
                .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
            Text("Website Setup")
                .font(.title2).fontWeight(.bold)
            Text("Enter the admin PIN to configure which websites are allowed in whitelist mode.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            SecureField("Admin PIN", text: $enteredPin)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .frame(maxWidth: 200)
                .multilineTextAlignment(.center)

            Button("Unlock") {
                if enteredPin == adminPin {
                    isUnlocked = true
                    loadCurrentSelection()
                } else {
                    enteredPin = ""
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0, green: 0.4, blue: 0.15))
            .disabled(enteredPin.isEmpty)
            Spacer()
        }
        .navigationTitle("Website Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    var unlockedView: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Image(systemName: "globe.badge.checkmark").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Select Allowed Websites")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(selectionSummary)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Whitelist Configuration")
            } footer: {
                Text("Select all websites this device should be allowed to visit. These become the whitelist when admin enables 'Allow Only Listed Sites' mode. Websites appear from browsing history.")
            }

            if let msg = savedMessage {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(msg).foregroundStyle(.green)
                    }
                }
            }

            Section {
                Button {
                    Task { await saveWebsiteSelection() }
                } label: {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        else { Image(systemName: "icloud.and.arrow.up") }
                        Text(isSaving ? "Saving..." : "Save & Apply")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 0, green: 0.4, blue: 0.15))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isSaving)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Website Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #if !targetEnvironment(simulator)
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                FamilyActivityPicker(selection: $webSelection)
                    .navigationTitle("Select Allowed Sites")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPicker = false }
                        }
                    }
            }
        }
        #endif
    }

    #if targetEnvironment(simulator)
    var selectionSummary: String { "Requires real device" }
    #else
    var selectionSummary: String {
        let sites = webSelection.webDomainTokens.count
        let cats = webSelection.categoryTokens.count
        if sites == 0 && cats == 0 { return "No sites selected yet" }
        var parts: [String] = []
        if sites > 0 { parts.append("\(sites) website\(sites == 1 ? "" : "s")") }
        if cats > 0 { parts.append("\(cats) categor\(cats == 1 ? "y" : "ies")") }
        return parts.joined(separator: ", ") + " allowed"
    }
    #endif

    private func loadCurrentSelection() {
        #if !targetEnvironment(simulator)
        guard let base64 = UserDefaults.standard.string(forKey: "screentime.websiteSelection"),
              let data = Data(base64Encoded: base64),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return }
        webSelection = selection
        #endif
    }

    private func saveWebsiteSelection() async {
        isSaving = true
        #if !targetEnvironment(simulator)
        // Store tokens locally (device-specific, used in applyWebsiteRestrictions)
        if let data = try? JSONEncoder().encode(webSelection) {
            UserDefaults.standard.set(data.base64EncodedString(), forKey: "screentime.websiteSelection")
        }
        // Apply immediately
        settingsManager.applyWebsiteRestrictions()

        // Also upload count info to Firebase so admin can see the setup status
        guard let user = auth.currentUser else { isSaving = false; return }
        let token = await auth.freshToken() ?? user.idToken
        let report: [String: Any] = [
            "siteCount": webSelection.webDomainTokens.count,
            "categoryCount": webSelection.categoryTokens.count,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
        if let url = URL(string: "https://applerestrictions-default-rtdb.firebaseio.com/users/\(user.uid)/websiteSetup.json?auth=\(token)"),
           let body = try? JSONSerialization.data(withJSONObject: report) {
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            _ = try? await URLSession.shared.data(for: req)
        }
        #endif
        isSaving = false
        savedMessage = "Saved! \(selectionSummary)"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        savedMessage = nil
    }
}

// MARK: - Pending Website Row
//
// One-tap flow: child taps "Allow" → domain added to allowedWebsites in Firebase
// settings → ContentBlockerService generates new Safari rules → no picker needed.

struct PendingWebsiteRow: View {
    let pushKey: String
    let domain: String
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    @State private var isAdding = false
    @State private var added = false
    @State private var addError: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(domain)
                    .font(.subheadline).fontWeight(.medium)
                if let err = addError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                } else {
                    Text(added ? "Added to whitelist" : "Admin wants to allow this site")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()

            if added {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button {
                    Task { await allowDomain() }
                } label: {
                    Group {
                        if isAdding {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Allow", systemImage: "plus.circle.fill")
                                .font(.caption).fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isAdding)
            }
        }
        .padding(.vertical, 4)
    }

    /// Add domain to allowedWebsites in Firebase config → content blocker auto-updates.
    private func allowDomain() async {
        isAdding = true
        addError = nil

        guard let user = auth.currentUser else {
            addError = "Not signed in"
            isAdding = false; return
        }
        let token = await auth.freshToken() ?? user.idToken
        let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

        // Fetch current settings from Firebase
        guard let getURL = URL(string: "\(dbURL)/users/\(user.uid)/settings.json?auth=\(token)"),
              let (data, _) = try? await URLSession.shared.data(from: getURL) else {
            addError = "Network error"
            isAdding = false; return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var config = (try? decoder.decode(ScreenTimeConfiguration.self, from: data)) ?? ScreenTimeConfiguration()

        // Add domain if not already present
        let clean = domain.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        if !config.allowedWebsites.contains(clean) {
            config.allowedWebsites.append(clean)
        }
        // Switch to whitelist mode so the content blocker actually enforces it
        config.websiteFilterMode = .whitelist
        config.contentBlockerEnabled = true

        // Save back to Firebase
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let encoded = try? encoder.encode(config),
              let putURL = URL(string: "\(dbURL)/users/\(user.uid)/settings.json?auth=\(token)") else {
            addError = "Encode error"
            isAdding = false; return
        }
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encoded
        _ = try? await URLSession.shared.data(for: req)

        // Apply locally right now
        #if !targetEnvironment(simulator)
        settingsManager.applyRemoteConfiguration(config)
        #endif

        // Remove this entry from pending list
        await syncService.removePendingWebsite(pushKey: pushKey)

        isAdding = false
        added = true
    }
}

// MARK: - App Request Sheet

/// Local iTunes Search API result — never persisted, only used to build an AppRequest.
struct ChildAppSearchResult: Identifiable, Equatable {
    let id: String
    let name: String
    let iconURL: String
    let category: String
    let sellerName: String
}

struct AppRequestSheet: View {
    @Binding var query: String
    @Binding var results: [ChildAppSearchResult]
    @Binding var isSearching: Bool
    @Binding var error: String?
    @Binding var selected: ChildAppSearchResult?
    @Binding var reason: String
    @Binding var isSending: Bool
    let onSearch: () async -> Void
    let onSend: () async -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal).padding(.top, 8).padding(.bottom, 6)

                if isSearching {
                    Spacer(); ProgressView("Searching…"); Spacer()
                } else if let error, results.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.app").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("Search the App Store for the app you want and ask your admin for approval.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    Spacer()
                } else {
                    List(results) { app in
                        Button { selected = app } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: app.iconURL)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2))
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                    if !app.sellerName.isEmpty {
                                        Text(app.sellerName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if selected == app {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }

                if selected != nil {
                    Divider()
                    VStack(spacing: 8) {
                        TextField("Why do you need it? (optional)", text: $reason, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await onSend() }
                        } label: {
                            if isSending {
                                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 44)
                            } else {
                                Text("Send Request to Admin")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isSending)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                }
            }
            .navigationTitle("Request App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the App Store…", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await onSearch() } }
            if !query.isEmpty {
                Button { query = ""; results = []; error = nil; selected = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            Button("Search") { Task { await onSearch() } }
                .font(.subheadline).fontWeight(.medium)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - My Apps Sheet (child labels their installed apps for the admin)

#if !targetEnvironment(simulator)
import FamilyControls
import ManagedSettings

struct MyAppsSheet: View {
    @Binding var initialSelection: FamilyActivitySelection
    let existing: [(key: String, app: InstalledApp)]
    /// onSubmit receives an array of (name, single-token base64 selection, isCategory) entries.
    let onSubmit: ([(String, String, Bool)]) -> Void
    let onRemove: (String) -> Void
    let onClose: () -> Void

    @State private var showPicker = false
    @State private var nameForApp: [ApplicationToken: String] = [:]
    @State private var nameForCat: [ActivityCategoryToken: String] = [:]
    @State private var submitting = false

    private var hasPendingNames: Bool {
        !initialSelection.applicationTokens.isEmpty || !initialSelection.categoryTokens.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick the apps you have, then type the name for each. Your admin sees this list and can set time limits per app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        showPicker = true
                    } label: {
                        Label("Pick Apps to Add", systemImage: "plus.app")
                    }
                }

                if hasPendingNames {
                    Section {
                        ForEach(Array(initialSelection.applicationTokens), id: \.self) { token in
                            HStack(spacing: 10) {
                                Label(token).labelStyle(.iconOnly).frame(width: 32, height: 32)
                                TextField("Name (e.g. Instagram)", text: Binding(
                                    get: { nameForApp[token] ?? "" },
                                    set: { nameForApp[token] = $0 }
                                ))
                            }
                        }
                        ForEach(Array(initialSelection.categoryTokens), id: \.self) { token in
                            HStack(spacing: 10) {
                                Label(token).labelStyle(.iconOnly).frame(width: 32, height: 32)
                                TextField("Category name (e.g. Social Media)", text: Binding(
                                    get: { nameForCat[token] ?? "" },
                                    set: { nameForCat[token] = $0 }
                                ))
                            }
                        }
                        Button {
                            submitAll()
                        } label: {
                            HStack {
                                if submitting { ProgressView() } else { Image(systemName: "checkmark.circle.fill") }
                                Text(submitting ? "Saving…" : "Save All")
                            }
                        }
                        .disabled(submitting || !allNamed)
                    } header: { Text("Name Each") }
                      footer: { Text("Each app needs a name before it can be saved.") }
                }

                if !existing.isEmpty {
                    Section {
                        ForEach(existing, id: \.key) { item in
                            HStack {
                                Text(item.app.name.isEmpty ? "(unnamed)" : item.app.name)
                                if item.app.isCategory {
                                    Text("category").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { onRemove(item.key) } label: {
                                    Image(systemName: "trash").foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: { Text("My App Library (\(existing.count))") }
                }
            }
            .navigationTitle("My Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
            }
            .familyActivityPicker(isPresented: $showPicker, selection: $initialSelection)
        }
    }

    private var allNamed: Bool {
        for token in initialSelection.applicationTokens {
            if (nameForApp[token] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        for token in initialSelection.categoryTokens {
            if (nameForCat[token] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    private func submitAll() {
        submitting = true
        var entries: [(String, String, Bool)] = []
        let encoder = JSONEncoder()
        for token in initialSelection.applicationTokens {
            let name = (nameForApp[token] ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var single = FamilyActivitySelection()
            single.applicationTokens = [token]
            if let data = try? encoder.encode(single) {
                entries.append((name, data.base64EncodedString(), false))
            }
        }
        for token in initialSelection.categoryTokens {
            let name = (nameForCat[token] ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var single = FamilyActivitySelection()
            single.categoryTokens = [token]
            if let data = try? encoder.encode(single) {
                entries.append((name, data.base64EncodedString(), true))
            }
        }
        onSubmit(entries)
        // Clear so the sheet can be reused for another batch.
        initialSelection = FamilyActivitySelection()
        nameForApp.removeAll()
        nameForCat.removeAll()
        submitting = false
    }
}
#endif

// MARK: - Captive Portal Sheet

/// Shown when the child device is on Wi-Fi but Firebase can't reach the
/// server — a strong signal the network has a captive portal (hotel /
/// coffee shop / school) and the forced DoH profile can't punch through.
struct CaptivePortalSheet: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Wi-Fi Sign-in Required")
                .font(.title2).fontWeight(.bold)
            Text("This network looks like it needs a login page before it lets traffic through. Because B-SAFE forces secure DNS, the device can't reach the login page on its own.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button { onOpen() } label: {
                Text("Open Login Page")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)

            Button("Dismiss", action: onDismiss)
                .padding(.bottom, 32)
        }
        .padding(.top, 32)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }
}

// MARK: - Pending App Row

struct PendingAppRow: View {
    let pushKey: String
    let app: RecommendedApp
    @EnvironmentObject var syncService: RemoteSyncService

    @State private var isDismissing = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: app.iconURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "app").foregroundStyle(.secondary))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.appName)
                    .font(.subheadline).fontWeight(.medium)
                if !app.category.isEmpty {
                    Text(app.category)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !app.sellerName.isEmpty {
                    Text(app.sellerName)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                presentOverlay(appID: app.appStoreID)
            } label: {
                Text("GET")
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                isDismissing = true
                Task {
                    await syncService.removePendingApp(pushKey: pushKey)
                    isDismissing = false
                }
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
    }

    /// SKOverlay shows a compact bottom banner — GET button → Face ID → installs.
    /// Stays inside B-SAFE, no sheet, no App Store navigation.
    private func presentOverlay(appID: String) {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        let config = SKOverlay.AppConfiguration(appIdentifier: appID, position: .bottom)
        let overlay = SKOverlay(configuration: config)
        overlay.present(in: scene)
    }
}


// MARK: - Safari View

#if !targetEnvironment(simulator)
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif

// MARK: - Status Row

struct StatusRow: View {
    let icon: String
    let label: String
    let value: String
    let active: Bool
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(active ? color : .secondary)
                .frame(width: 20)
            Text(label)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? color : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? color.opacity(0.12) : Color.clear, in: Capsule())
        }
    }
}

// MARK: - Setup Checklist

struct SetupChecklistView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @EnvironmentObject var authManager: ActiveAuthorizationManager
    @Environment(\.dismiss) var dismiss

    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var contentBlockerOn = false
    @State private var networkFilterOn = false
    @State private var networkFilterError: String? = nil
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ChecklistRow(
                        title: "Screen Time Authorized",
                        detail: "Allows B-SAFE to enforce restrictions",
                        done: authManager.isAuthorized,
                        action: authManager.isAuthorized ? nil : {
                            Task { await authManager.requestAuthorization() }
                        },
                        actionLabel: "Authorize"
                    )

                    ChecklistRow(
                        title: "Notifications Allowed",
                        detail: "Admin can send alerts to this device",
                        done: notifStatus == .authorized || notifStatus == .provisional,
                        action: notifStatus == .denied ? {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } : (notifStatus == .notDetermined ? {
                            syncService.requestNotificationPermission()
                        } : nil),
                        actionLabel: notifStatus == .denied ? "Open Settings" : "Enable"
                    )

                    ChecklistRow(
                        title: "Content Blocker Active",
                        detail: "Enables website filtering in Safari",
                        done: contentBlockerOn,
                        action: contentBlockerOn ? nil : {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        },
                        actionLabel: "Open Settings"
                    )

                    #if !targetEnvironment(simulator)
                    ChecklistRow(
                        title: "Network Filter Active",
                        detail: networkFilterError ?? "Blocks websites system-wide across all apps",
                        done: networkFilterOn,
                        action: networkFilterOn ? nil : {
                            networkFilterError = nil
                            Task {
                                let err = await ContentFilterService.shared.enable(config: settingsManager.configuration)
                                networkFilterOn = await ContentFilterService.shared.isEnabled()
                                if !networkFilterOn { networkFilterError = err ?? "Failed — check console" }
                            }
                        },
                        actionLabel: "Enable"
                    )
                    #endif

                    ChecklistRow(
                        title: "Connected to Admin",
                        detail: "Real-time sync with admin dashboard",
                        done: syncService.isOnline,
                        action: nil,
                        actionLabel: nil
                    )

                    ChecklistRow(
                        title: "Name Set",
                        detail: "Admin can identify this device by name",
                        done: !syncService.displayName.isEmpty,
                        action: nil,
                        actionLabel: nil
                    )
                } header: {
                    Text("Setup Status")
                } footer: {
                    let doneCount = [
                        authManager.isAuthorized,
                        notifStatus == .authorized || notifStatus == .provisional,
                        contentBlockerOn,
                        networkFilterOn,
                        syncService.isOnline,
                        !syncService.displayName.isEmpty
                    ].filter { $0 }.count
                    Text("\(doneCount) of 6 steps complete")
                }
            }
            .navigationTitle("Setup Checklist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadStatuses()
                isLoading = false
            }
        }
    }

    private func loadStatuses() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        #if !targetEnvironment(simulator)
        let id = "com.abbrachfeld.screentimecontrolabbrach.BSAFEContentBlocker"
        if let state = try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: id) {
            contentBlockerOn = state.isEnabled
        }
        networkFilterOn = await ContentFilterService.shared.isEnabled()
        #endif
    }
}

// MARK: - Filter Logs View

struct FilterLogsView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @State private var logs: [(host: String, allowed: Bool, reason: String, timestamp: Date)] = []
    @State private var isUploading = false
    @State private var uploadDone = false
    private let appGroupID = "group.com.abbrachfeld.bsafe"
    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("No Filter Logs").font(.headline)
                        Text("Network filter decisions will appear here once the filter is active.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Text("\(logs.filter { $0.allowed }.count) allowed · \(logs.filter { !$0.allowed }.count) blocked · \(logs.count) total")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Section("Recent Decisions") {
                            ForEach(Array(logs.prefix(100).enumerated()), id: \.offset) { _, entry in
                                HStack(spacing: 10) {
                                    Image(systemName: entry.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(entry.allowed ? .green : .red)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.host).font(.subheadline).lineLimit(1)
                                        Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(entry.timestamp.formatted(.relative(presentation: .named)))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await uploadLogs() }
                    } label: {
                        if isUploading { ProgressView().scaleEffect(0.8) }
                        else if uploadDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Text("Send to Admin") }
                    }
                    .disabled(isUploading || logs.isEmpty)
                }
            }
        }
        .onAppear { loadLogs() }
    }

    private func loadLogs() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let raw = defaults.array(forKey: "bsafe.filter.logs") as? [[String: Any]] else { return }
        logs = raw.compactMap { d -> (host: String, allowed: Bool, reason: String, timestamp: Date)? in
            guard let host = d["host"] as? String,
                  let allowed = d["allowed"] as? Bool,
                  let ts = d["timestamp"] as? Double else { return nil }
            let reason = d["reason"] as? String ?? ""
            return (host, allowed, reason, Date(timeIntervalSince1970: ts))
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private func uploadLogs() async {
        guard !logs.isEmpty else { return }
        isUploading = true
        let token = await auth.freshToken() ?? ""
        guard let uid = auth.currentUser?.uid else { isUploading = false; return }

        let payload: [[String: Any]] = logs.map { entry in
            ["host": entry.host, "allowed": entry.allowed, "reason": entry.reason,
             "timestamp": entry.timestamp.timeIntervalSince1970 * 1000]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "\(dbURL)/users/\(uid)/filterLogs.json?auth=\(token)") else {
            isUploading = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try? await URLSession.shared.data(for: req)
        isUploading = false
        uploadDone = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        uploadDone = false
    }
}

struct ChecklistRow: View {
    let title: String
    let detail: String
    let done: Bool
    let action: (() -> Void)?
    let actionLabel: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline).fontWeight(.medium)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done, let action, let label = actionLabel {
                Button(label, action: action)
                    .font(.caption).fontWeight(.semibold)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0, green: 0.4, blue: 0.15))
            }
        }
        .padding(.vertical, 4)
    }
}
