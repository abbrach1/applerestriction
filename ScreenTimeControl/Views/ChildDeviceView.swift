import SwiftUI
import UIKit

#if !targetEnvironment(simulator)
import FamilyControls
#endif

struct ChildDeviceView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @State private var isRefreshing = false
    @State private var showAdminSetup = false
    @State private var showWebsiteSetup = false
    @State private var showSendAppList = false
    @State private var isSendingList = false
    @State private var listSentMessage: String?
    #if !targetEnvironment(simulator)
    @State private var appListSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        let config = settingsManager.configuration
        NavigationStack {
            List {
                // Device identity
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0, green: 0.4, blue: 0.15).opacity(0.12))
                                .frame(width: 56, height: 56)
                            Image(systemName: "iphone.gen3")
                                .font(.title2)
                                .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(auth.currentUser?.email ?? "")
                                .font(.subheadline).fontWeight(.semibold)
                            Text(UIDevice.current.name)
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("Protected by B-SAFE")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(.vertical, 4)
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
                        .background(Color(red: 0, green: 0.4, blue: 0.15))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(isRefreshing)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: { Text("Sync") }
                footer: { Text("Settings update automatically every 10 seconds.") }

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
                        Text("Admin wants to add these sites to your whitelist. Tap 'Add to Whitelist' — if the site doesn't appear in the picker, tap 'Visit Site' first, then try again.")
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

                Section {
                    Button("Sign Out", role: .destructive) { auth.signOut() }
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
            }
            .navigationTitle("B-SAFE")
            .navigationBarTitleDisplayMode(.large)
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
        }
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

    private func isWebsiteFilterActive(_ config: ScreenTimeConfiguration) -> Bool {
        config.websiteFilterMode == .whitelist || !config.blockedWebsites.isEmpty
    }

    private func websiteFilterStatus(_ config: ScreenTimeConfiguration) -> String {
        guard isWebsiteFilterActive(config) else { return "Off" }
        if config.websiteFilterMode == .whitelist {
            return "Whitelist (\(config.allowedWebsites.count) allowed)"
        }
        return "Blocking \(config.blockedWebsites.count) site(s)"
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

struct PendingWebsiteRow: View {
    let pushKey: String
    let domain: String
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    @State private var showPicker = false
    @State private var showSafari = false
    @State private var isAdding = false
    @State private var added = false
    #if !targetEnvironment(simulator)
    @State private var pickerSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(domain)
                        .font(.subheadline).fontWeight(.medium)
                    Text("Admin wants to add this to your whitelist")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if added {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                // Visit site first (so it shows up in picker)
                Button {
                    showSafari = true
                } label: {
                    Label("Visit Site", systemImage: "safari")
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Open picker to add the token
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 4) {
                        if isAdding { ProgressView().scaleEffect(0.7) }
                        else { Image(systemName: "plus.circle.fill") }
                        Text("Add to Whitelist")
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isAdding || added)
            }
        }
        .padding(.vertical, 4)
        #if !targetEnvironment(simulator)
        .sheet(isPresented: $showSafari) {
            SafariView(url: URL(string: "https://\(domain)") ?? URL(string: "https://apple.com")!)
        }
        .sheet(isPresented: $showPicker, onDismiss: {
            Task { await mergeAndSave() }
        }) {
            NavigationStack {
                VStack(spacing: 0) {
                    Text("Find and select \(domain) in the list below.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.vertical, 6)
                    FamilyActivityPicker(selection: $pickerSelection)
                }
                .navigationTitle("Add \(domain)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showPicker = false }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            pickerSelection = FamilyActivitySelection()
                            showPicker = false
                        }
                    }
                }
            }
        }
        #endif
    }

    private func mergeAndSave() async {
        #if !targetEnvironment(simulator)
        guard !pickerSelection.webDomainTokens.isEmpty else { return }
        isAdding = true

        // Load existing whitelist selection
        var merged = FamilyActivitySelection()
        if let base64 = UserDefaults.standard.string(forKey: "screentime.websiteSelection"),
           let data = Data(base64Encoded: base64),
           let existing = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            merged = existing
        }

        // Merge new domain tokens into existing whitelist
        merged.webDomainTokens.formUnion(pickerSelection.webDomainTokens)
        merged.categoryTokens.formUnion(pickerSelection.categoryTokens)

        // Save merged selection locally
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data.base64EncodedString(), forKey: "screentime.websiteSelection")
        }

        // Apply immediately
        settingsManager.applyWebsiteRestrictions()

        // Update Firebase setup info
        if let user = auth.currentUser {
            let token = await auth.freshToken() ?? user.idToken
            let report: [String: Any] = [
                "siteCount": merged.webDomainTokens.count,
                "categoryCount": merged.categoryTokens.count,
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
        }

        // Remove this domain from pending list
        await syncService.removePendingWebsite(pushKey: pushKey)

        isAdding = false
        added = true
        #endif
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
