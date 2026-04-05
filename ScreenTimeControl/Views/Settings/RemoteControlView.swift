import SwiftUI

struct RemoteControlView: View {
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack {
                        Circle()
                            .fill(syncService.isOnline ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(syncService.isOnline ? "Connected to Firebase" : "Offline")
                        Spacer()
                        if let lastSync = syncService.lastSyncDate {
                            Text(lastSync, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = syncService.syncError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(error).font(.caption)
                        }
                    }
                }

                Section("Sync") {
                    Button {
                        syncService.startListening()
                    } label: {
                        Label("Start Listening", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    Button {
                        syncService.stopListening()
                    } label: {
                        Label("Stop Listening", systemImage: "antenna.radiowaves.left.and.right.slash")
                    }

                    Button {
                        Task { await syncService.manualSync() }
                    } label: {
                        Label("Manual Sync", systemImage: "arrow.triangle.2.circlepath")
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
                                    Text(command.type.rawValue).font(.subheadline)
                                    Text(command.timestamp, style: .relative)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Remote Control")
        }
    }

    private func commandIcon(for type: RemoteCommand.CommandType) -> String {
        switch type {
        case .lockDevice:         return "lock.fill"
        case .unlockAll:          return "lock.open.fill"
        case .updateBlockedApps:  return "shield.fill"
        case .updateDowntime:     return "moon.fill"
        case .updateTimeLimits:   return "timer"
        case .updateWebsites:     return "globe"
        case .refreshSettings:    return "arrow.triangle.2.circlepath"
        }
    }
}
