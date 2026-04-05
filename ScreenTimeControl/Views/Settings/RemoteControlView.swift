import SwiftUI

struct RemoteControlView: View {
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    @State private var pairCode: String = ""
    @State private var showPairInput: Bool = false
    @State private var selectedRole: DeviceRole = .child

    enum DeviceRole: String, CaseIterable {
        case parent = "Parent (Controller)"
        case child = "Child (Controlled)"
    }

    var body: some View {
        NavigationStack {
            List {
                // Role Selection
                Section {
                    Picker("Device Role", selection: $selectedRole) {
                        ForEach(DeviceRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Setup")
                } footer: {
                    Text(selectedRole == .parent
                         ? "As a parent, you can control other devices remotely."
                         : "As a child device, this device will receive remote commands.")
                }

                // Pairing
                if !syncService.isPaired {
                    Section("Pairing") {
                        if selectedRole == .child {
                            Button {
                                Task { await syncService.generatePairingCode() }
                            } label: {
                                HStack {
                                    Image(systemName: "qrcode")
                                    Text("Generate Pairing Code")
                                }
                            }

                            if !syncService.pairingCode.isEmpty {
                                VStack(spacing: 8) {
                                    Text("Your Pairing Code")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(syncService.pairingCode)
                                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.blue)
                                    Text("Share this code with the parent device")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                        } else {
                            HStack {
                                TextField("Enter pairing code", text: $pairCode)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)

                                Button("Pair") {
                                    Task { await syncService.pairWithDevice(code: pairCode) }
                                }
                                .disabled(pairCode.count != 6)
                            }
                        }
                    }
                }

                // Connected Devices (Parent view)
                if selectedRole == .parent && !syncService.connectedDevices.isEmpty {
                    Section("Connected Devices") {
                        ForEach(syncService.connectedDevices) { device in
                            NavigationLink {
                                DeviceControlView(device: device)
                            } label: {
                                HStack {
                                    Image(systemName: "iphone")
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                            .font(.headline)
                                        Text("\(device.model) · iOS \(device.osVersion)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Circle()
                                        .fill(device.isOnline ? .green : .gray)
                                        .frame(width: 10, height: 10)
                                }
                            }
                        }
                    }
                }

                // Remote Status (Child view)
                if selectedRole == .child && syncService.isPaired {
                    Section("Remote Status") {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text("Listening for commands")
                                .foregroundStyle(.green)
                        }

                        Button {
                            syncService.startPolling()
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Start Listening")
                            }
                        }

                        Button {
                            syncService.stopPolling()
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                Text("Stop Listening")
                            }
                        }
                    }

                    Section("Pending Commands") {
                        if syncService.pendingCommands.isEmpty {
                            Text("No pending commands")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(syncService.pendingCommands) { command in
                                HStack {
                                    Image(systemName: commandIcon(for: command.type))
                                    VStack(alignment: .leading) {
                                        Text(command.type.rawValue)
                                            .font(.subheadline)
                                        Text(command.timestamp, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                // Sync
                if syncService.isPaired {
                    Section {
                        Button {
                            Task {
                                await syncService.pushSettings(settingsManager.configuration)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.blue)
                                Text("Push Settings to Server")
                            }
                        }

                        Button {
                            Task {
                                if let config = await syncService.pullSettings() {
                                    settingsManager.applyRemoteConfiguration(config)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Pull Settings from Server")
                            }
                        }
                    } header: {
                        Text("Manual Sync")
                    }
                }
            }
            .navigationTitle("Remote Control")
        }
    }

    private func commandIcon(for type: RemoteCommand.CommandType) -> String {
        switch type {
        case .lockDevice: return "lock.fill"
        case .unlockAll: return "lock.open.fill"
        case .updateBlockedApps: return "shield.fill"
        case .updateDowntime: return "moon.fill"
        case .updateTimeLimits: return "timer"
        case .updateWebsites: return "globe"
        case .refreshSettings: return "arrow.triangle.2.circlepath"
        }
    }
}

struct DeviceControlView: View {
    let device: DeviceInfo
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "iphone")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(device.name)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("\(device.model) · iOS \(device.osVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Last seen: \(device.lastSeen, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Remote Commands") {
                Button {
                    sendCommand(.lockDevice)
                } label: {
                    Label("Lock All Apps", systemImage: "lock.fill")
                        .foregroundStyle(.red)
                }

                Button {
                    sendCommand(.unlockAll)
                } label: {
                    Label("Unlock All Apps", systemImage: "lock.open.fill")
                        .foregroundStyle(.green)
                }

                Button {
                    sendCommand(.refreshSettings)
                } label: {
                    Label("Refresh Settings", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section("Push Current Settings") {
                Button {
                    Task {
                        await syncService.pushSettings(settingsManager.configuration)
                        sendCommand(.updateBlockedApps)
                    }
                } label: {
                    Label("Send App Restrictions", systemImage: "shield.fill")
                }

                Button {
                    Task {
                        await syncService.pushSettings(settingsManager.configuration)
                        sendCommand(.updateDowntime)
                    }
                } label: {
                    Label("Send Downtime Schedule", systemImage: "moon.fill")
                }

                Button {
                    Task {
                        await syncService.pushSettings(settingsManager.configuration)
                        sendCommand(.updateTimeLimits)
                    }
                } label: {
                    Label("Send Time Limits", systemImage: "timer")
                }
            }
        }
        .navigationTitle(device.name)
    }

    private func sendCommand(_ type: RemoteCommand.CommandType) {
        let command = RemoteCommand(type: type)
        Task {
            await syncService.sendCommand(command, toDevice: device.id)
        }
    }
}
