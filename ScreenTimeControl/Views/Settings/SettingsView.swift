import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: ActiveAuthorizationManager
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var showRevokeAlert = false

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
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Authorized")
                            .foregroundStyle(.green)
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
                        syncService.stopPolling()
                    } label: {
                        Text("Remove All Restrictions")
                    }
                }

                // About
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
                            .font(.caption)
                    }

                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
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
