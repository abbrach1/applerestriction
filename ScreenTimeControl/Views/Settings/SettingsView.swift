import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: ActiveAuthorizationManager
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var showRevokeAlert = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {

                // Device Info
                Section("Device Info") {
                    HStack {
                        Text("Device ID")
                        Spacer()
                        Text(DeviceInfo.current.id.prefix(8) + "...")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Text("Device Name")
                        Spacer()
                        Text(DeviceInfo.current.name)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("iOS Version")
                        Spacer()
                        Text(DeviceInfo.current.osVersion)
                            .foregroundStyle(.secondary)
                    }
                }

                // Authorization
                Section {
                    HStack {
                        Text("Screen Time Access")
                        Spacer()
                        if authManager.isAuthorized {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Authorized").foregroundStyle(.green)
                        } else {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            Text("Not Authorized").foregroundStyle(.orange)
                        }
                    }

                    if !authManager.isAuthorized {
                        Button {
                            Task { await authManager.requestAuthorization() }
                        } label: {
                            HStack {
                                if authManager.isRequesting { ProgressView() }
                                Text("Re-authorize Screen Time")
                            }
                        }
                        .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                    }

                    Button(role: .destructive) {
                        showRevokeAlert = true
                    } label: {
                        Text("Revoke Screen Time Access")
                    }
                } header: {
                    Text("Authorization")
                } footer: {
                    Text("Revoking access will remove all restrictions set by this app.")
                }

                // Reset
                Section {
                    Button(role: .destructive) {
                        settingsManager.unlockAll()
                    } label: {
                        Text("Remove All Restrictions")
                    }
                }

                // Account
                Section {
                    if let user = auth.currentUser {
                        HStack {
                            Text("Logged in as")
                            Spacer()
                            Text(user.email)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                } header: {
                    Text("Account")
                }

                Section("About") {
                    HStack {
                        Text("App")
                        Spacer()
                        Text("B-SAFE")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Developer")
                        Spacer()
                        Text("Aryeh Brachfeld")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Revoke Access?", isPresented: $showRevokeAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Revoke", role: .destructive) {
                    authManager.revokeAuthorization()
                }
            } message: {
                Text("This will remove all Screen Time restrictions set by this app and revoke authorization.")
            }
        }
    }
}
