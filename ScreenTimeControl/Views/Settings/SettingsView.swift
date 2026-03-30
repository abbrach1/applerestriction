import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: ActiveAuthorizationManager
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var firebaseURL: String = ""
    @State private var pollingInterval: Double = 30
    @State private var showRevokeAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // Firebase Configuration
                Section {
                    TextField(
                        "https://applerestrictions-default-rtdb.firebaseio.com",
                        text: $firebaseURL
                    )
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button("Save") {
                        syncService.firebaseURL = firebaseURL
                    }
                    .disabled(firebaseURL.isEmpty)
                } header: {
                    Text("Firebase Database URL")
                } footer: {
                    Text("1. Go to console.firebase.google.com\n2. Create project → Realtime Database → Test mode\n3. Copy the database URL and paste it above.")
                }

                // Polling
                Section {
                    VStack(alignment: .leading) {
                        Text("Poll every \(Int(pollingInterval)) seconds")
                        Slider(value: $pollingInterval, in: 10...120, step: 5)
                    }
                } header: {
                    Text("Polling Interval")
                } footer: {
                    Text("How often the device checks for new remote commands.")
                }

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
                        Text("AB Brachfeld Kosher iPhone Filter")
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
                        Text("AB Brachfeld")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                firebaseURL = syncService.firebaseURL
            }
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
