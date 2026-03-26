import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthorizationManager
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ScreenTimeSettingsManager

    @State private var serverURL: String = UserDefaults.standard.string(forKey: "remote.baseURL") ?? ""
    @State private var pollingInterval: Double = 30
    @State private var showRevokeAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // Server Configuration
                Section {
                    TextField("Server URL", text: $serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save Server URL") {
                        UserDefaults.standard.set(serverURL, forKey: "remote.baseURL")
                    }
                } header: {
                    Text("Remote Server")
                } footer: {
                    Text("Enter the URL of your remote control server. You need to deploy your own backend for remote features to work.")
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
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Frameworks")
                        Spacer()
                        Text("FamilyControls, ManagedSettings")
                            .foregroundStyle(.secondary)
                            .font(.caption)
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
