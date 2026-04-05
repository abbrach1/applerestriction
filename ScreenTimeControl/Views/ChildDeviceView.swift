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
    @State private var showAdminSetup = false
    @State private var showWebsiteSetup = false
    @State private var showSendAppList = false
    @State private var isSendingList = false
    @State private var listSentMessage: String?
    @State private var contentBlockerEnabled: Bool = true  // assume enabled until checked
    @State private var isEditingName = false
    @State private var nameInput = ""
    @State private var showUnlockRequest = false
    @State private var unlockReason = ""
    @State private var showChecklist = false
    @State private var showWebsiteRequest = false
    @State private var websiteRequestDomain = ""
    @State private var websiteRequestReason = ""
    @State private var showBypassEntry = false
    @State private var bypassCode = ""
    @State private var bypassResult: Bool? = nil   // nil=idle, true=ok, false=wrong
    #if !targetEnvironment(simulator)
    @State private var appListSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        let config = settingsManager.configuration
        TabView {
            mainTab(config: config)
                .tabItem { Label("Home", systemImage: "shield.checkered") }

            if config.websiteFilterMode == .whitelist && !config.allowedWebsites.isEmpty {
                SafeBrowserView()
                    .environmentObject(settingsManager)
                    .tabItem { Label("Browser", systemImage: "globe") }
            }
        }
        .tint(Color(red: 0, green: 0.4, blue: 0.15))
    }

    @ViewBuilder
    private func mainTab(config: ScreenTimeConfiguration) -> some View {
        NavigationStack {
            List {
                // Device identity
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0, green: 0.4, blue: 0.15).opacity(0.12))
                                .frame(width: 56, height: 56)
                            Image(systemName: "person.fill")
                                .font(.title2)
                                .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            let name = syncService.displayName.isEmpty
                                ? (auth.currentUser?.email ?? "")
                                : syncService.displayName
                            Text(name)
                                .font(.subheadline).fontWeight(.semibold)
                            if !syncService.displayName.isEmpty {
                                Text(auth.currentUser?.email ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(UIDevice.current.name)
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("Protected by B-SAFE")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                        }
                        Spacer()
                        Button {
                            nameInput = syncService.displayName
                            isEditingName = true
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.title3)
                                .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15).opacity(0.6))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .alert("Your Name", isPresented: $isEditingName) {
                    TextField("Name (e.g. David)", text: $nameInput)
                        .autocorrectionDisabled()
                    Button("Save") {
                        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
                        Task { await syncService.setDisplayName(trimmed) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This name is shown to your admin.")
                }

                // Active restrictions
                Section("Active Restrictions") {
                    StatusRow(icon: "lock.fill", label: "Device Lock",
                              value: config.isLocked ? "LOCKED" : "Off",
                              active: config.isLocked, color: .red)
                    StatusRow(icon: "globe", label: "Website Filter",
                              value: websiteFilterStatus(config),
                              active: isWebsiteFilterActive(config), color: .blue)
                    StatusRow(icon: "square.grid.2x2.fill", label: "App Blocking",
                              value: appBlockingStatus(config),
                              active: isAppBlockingActive(config), color: .orange)
                    StatusRow(icon: "moon.fill", label: "Downtime",
                              value: downtimeStatus(config),
                              active: config.downtimeEnabled, color: .purple)
                    StatusRow(icon: "xmark.app.fill", label: "Block New Installs",
                              value: config.blockNewApps ? "On" : "Off",
                              active: config.blockNewApps, color: .orange)
                }

                // Sync
                Section {
                    // Offline / error banner
                    if !syncService.isOnline {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Device is offline")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Restrictions remain active. Syncing when reconnected.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    } else if let err = syncService.syncError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(err)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let last = syncService.lastSyncDate {
                        LabeledContent("Last Sync", value: last.formatted(.relative(presentation: .named)))
                            .font(.caption)
                    }
                    Button {
                        Task {
                            isRefreshing = true
                            await syncService.manualSync()
                            isRefreshing = false
                        }
                    } label: {
                        HStack {
                            if isRefreshing { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text(isRefreshing ? "Syncing..." : "Sync Settings Now")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(syncService.isOnline
                                    ? Color(red: 0, green: 0.4, blue: 0.15)
                                    : Color.gray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(isRefreshing || !syncService.isOnline)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: { Text("Sync") }
                footer: {
                    Text(syncService.isOnline
                         ? "Settings update automatically every 30 seconds."
                         : "Will sync automatically when back online.")
                }

                // Pending website approvals from admin
                if !syncService.pendingWebsites.isEmpty {
                    Section {
                        ForEach(Array(syncService.pendingWebsites), id: \.key) { pushKey, domain in
                            PendingWebsiteRow(pushKey: pushKey, domain: domain)
                                .environmentObject(auth)
                                .environmentObject(syncService)
                                .environmentObject(settingsManager)
                        }
                    } header: {
                        Label("Website Requests from Admin", systemImage: "globe.badge.exclamationmark")
                    } footer: {
                        Text("Tap Allow to instantly add the site to your whitelist. The Safari content blocker updates immediately — no picker required.")
                    }
                }

                // Content blocker warning — only shown in whitelist mode when extension is off
                if config.websiteFilterMode == .whitelist && !contentBlockerEnabled {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Website filter not active")
                                    .font(.subheadline).fontWeight(.semibold)
                                Text("Go to Settings → Safari → Extensions → enable B-SAFE Content Blocker")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Apps pushed by admin
                if !syncService.pendingApps.isEmpty {
                    Section {
                        ForEach(Array(syncService.pendingApps), id: \.key) { pushKey, app in
                            PendingAppRow(pushKey: pushKey, app: app)
                                .environmentObject(syncService)
                        }
                    } header: {
                        Label("Apps from Admin", systemImage: "arrow.down.app.fill")
                    } footer: {
                        Text("Tap Get to install directly without leaving B-SAFE. Swipe to dismiss after installing.")
                    }
                }

                // Send app list to admin for review
                Section {
                    if let msg = listSentMessage {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(msg).foregroundStyle(.green).font(.subheadline)
                        }
                    }
                    Button {
                        showSendAppList = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Send App List to Admin")
                                    .font(.subheadline).fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                Text("Select your apps so admin can review and approve them")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("App Review") }
                  footer: { Text("If new app installs are blocked, send your app list to request admin approval.") }

                // Website access requests
                Section {
                    ForEach(syncService.pendingWebsiteRequests, id: \.key) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "globe.badge.exclamationmark")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.request.domain)
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("Pending admin approval")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Cancel") {
                                    Task { await syncService.cancelWebsiteRequest(key: item.key) }
                                }
                                .font(.caption).foregroundStyle(.red)
                            }
                            .padding(.vertical, 2)
                        }

                        Button {
                            websiteRequestDomain = ""
                            websiteRequestReason = ""
                            showWebsiteRequest = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "globe.badge.exclamationmark")
                                    .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Request Website Access")
                                        .foregroundStyle(.primary)
                                    Text("Ask admin to allow a specific site")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("Website Requests") }
                    .alert("Request Website Access", isPresented: $showWebsiteRequest) {
                        TextField("Domain (e.g. youtube.com)", text: $websiteRequestDomain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        TextField("Reason (optional)", text: $websiteRequestReason)
                            .autocorrectionDisabled()
                        Button("Send Request") {
                            let domain = websiteRequestDomain.trimmingCharacters(in: .whitespaces)
                            let reason = websiteRequestReason.trimmingCharacters(in: .whitespaces)
                            guard !domain.isEmpty else { return }
                            Task { await syncService.sendWebsiteRequest(domain: domain, reason: reason) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your admin will be notified and can approve or deny.")
                    }
                }

                // Unlock request
                Section {
                    if syncService.pendingUnlockRequest != nil {
                        HStack(spacing: 12) {
                            ProgressView().tint(Color(red: 0, green: 0.4, blue: 0.15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock request pending")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Waiting for admin approval")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cancel") {
                                Task { await syncService.cancelUnlockRequest() }
                            }
                            .font(.caption).foregroundStyle(.red)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            unlockReason = ""
                            showUnlockRequest = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "lock.open.fill")
                                    .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Request Unlock")
                                        .foregroundStyle(.primary)
                                    Text("Ask admin to temporarily unlock the device")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    // Emergency bypass code entry (hidden-ish — below unlock request)
                    Button {
                        bypassCode = ""
                        bypassResult = nil
                        showBypassEntry = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enter Emergency Code")
                                    .foregroundStyle(.primary)
                                Text("Use a one-time code from your admin")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alert("Emergency Code", isPresented: $showBypassEntry) {
                        TextField("6-digit code", text: $bypassCode)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                        Button("Unlock") {
                            Task {
                                let ok = await syncService.redeemBypassCode(bypassCode.trimmingCharacters(in: .whitespaces))
                                bypassResult = ok
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Enter the emergency code your admin gave you.")
                    }
                    .alert(bypassResult == true ? "Unlocked!" : "Invalid Code",
                           isPresented: Binding(
                               get: { bypassResult != nil },
                               set: { if !$0 { bypassResult = nil } }
                           )) {
                        Button("OK") { bypassResult = nil }
                    } message: {
                        if bypassResult == true {
                            Text("Device is now unlocked for the permitted duration.")
                        } else {
                            Text("That code is invalid or already used. Ask your admin for a new one.")
                        }
                    }
                } header: { Text("Unlock Request") }
                .alert("Request Unlock", isPresented: $showUnlockRequest) {
                    TextField("Reason (optional)", text: $unlockReason)
                        .autocorrectionDisabled()
                    Button("Send Request") {
                        let r = unlockReason.trimmingCharacters(in: .whitespaces)
                        Task { await syncService.sendUnlockRequest(reason: r) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your admin will receive a notification and can approve or deny.")
                }

                Section {
                    Button("Sign Out", role: .destructive) { auth.signOut() }
                    Button {
                        showChecklist = true
                    } label: {
                        Label("Setup Checklist", systemImage: "checklist")
                            .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                            .font(.caption)
                    }
                    Button("App Blocking Setup") { showAdminSetup = true }
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Button("Website Whitelist Setup") { showWebsiteSetup = true }
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } footer: {
                    Text("App Blocking and Website Whitelist Setup require the admin PIN. Run these on the child's device to configure which apps are blocked and which websites are allowed.")
                        .font(.caption2)
                }
                .sheet(isPresented: $showChecklist) {
                    SetupChecklistView()
                        .environmentObject(auth)
                        .environmentObject(syncService)
                        .environmentObject(settingsManager)
                        .environmentObject(authManager)
                }
            }
            .navigationTitle("B-SAFE")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await checkContentBlockerState()
                updateInstallationBlock()
            }
            .onChange(of: syncService.pendingApps.count) { _ in
                updateInstallationBlock()
            }
            .sheet(isPresented: $showAdminSetup) {
                AdminSetupSheet()
                    .environmentObject(auth)
                    .environmentObject(syncService)
                    .environmentObject(settingsManager)
            }
            .sheet(isPresented: $showWebsiteSetup) {
                WebsiteSetupSheet()
                    .environmentObject(auth)
                    .environmentObject(settingsManager)
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

    private func isWebsiteFilterActive(_ config: ScreenTimeConfiguration) -> Bool {
        config.websiteFilterMode == .whitelist || !config.blockedWebsites.isEmpty
    }

    private func websiteFilterStatus(_ config: ScreenTimeConfiguration) -> String {
        if config.websiteFilterMode == .whitelist {
            let count = localWhitelistCount()
            return count > 0 ? "Whitelist (\(count) site\(count == 1 ? "" : "s"))" : "Whitelist — no sites set up yet"
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
                        syncService.isOnline,
                        !syncService.displayName.isEmpty
                    ].filter { $0 }.count
                    Text("\(doneCount) of 5 steps complete")
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
        #endif
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
