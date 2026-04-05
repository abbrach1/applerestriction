import SwiftUI
import UIKit

struct ChildDeviceView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @State private var isRefreshing = false
    @State private var syncError: String?

    var config: ScreenTimeConfiguration { settingsManager.configuration }

    var body: some View {
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

                // Active restrictions — shows exactly what the device has received
                Section("Active Restrictions") {
                    StatusRow(
                        icon: "lock.fill",
                        label: "Device Lock",
                        value: config.isLocked ? "LOCKED" : "Off",
                        active: config.isLocked,
                        color: .red
                    )
                    StatusRow(
                        icon: "globe",
                        label: "Website Filter",
                        value: websiteFilterStatus,
                        active: isWebsiteFilterActive,
                        color: .blue
                    )
                    StatusRow(
                        icon: "moon.fill",
                        label: "Downtime",
                        value: downtimeStatus,
                        active: config.downtimeEnabled,
                        color: .purple
                    )
                }

                // Website details if active
                if isWebsiteFilterActive {
                    Section("Website Details") {
                        LabeledContent("Mode", value: config.websiteFilterMode == .whitelist ? "Whitelist (allow only listed)" : "Blacklist (block listed)")
                        if config.websiteFilterMode == .blacklist && !config.blockedWebsites.isEmpty {
                            ForEach(config.blockedWebsites, id: \.self) { site in
                                Label(site, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        } else if config.websiteFilterMode == .whitelist && !config.allowedWebsites.isEmpty {
                            ForEach(config.allowedWebsites, id: \.self) { site in
                                Label(site, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                }

                // Sync
                Section {
                    if let last = syncService.lastSyncDate {
                        LabeledContent("Last Sync", value: last.formatted(.relative(presentation: .named)))
                            .font(.caption)
                    }

                    if let err = syncError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            isRefreshing = true
                            syncError = nil
                            await syncService.manualSync()
                            isRefreshing = false
                            if syncService.lastSyncDate == nil {
                                syncError = "Sync failed — check internet connection"
                            }
                        }
                    } label: {
                        HStack {
                            if isRefreshing {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
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
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Settings update automatically every 10 seconds.")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                }
            }
            .navigationTitle("B-SAFE")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    var isWebsiteFilterActive: Bool {
        if config.websiteFilterMode == .whitelist { return true }
        return !config.blockedWebsites.isEmpty
    }

    var websiteFilterStatus: String {
        if !isWebsiteFilterActive { return "Off" }
        if config.websiteFilterMode == .whitelist {
            return "Whitelist (\(config.allowedWebsites.count) allowed)"
        }
        return "Blocking \(config.blockedWebsites.count) site(s)"
    }

    var downtimeStatus: String {
        guard config.downtimeEnabled else { return "Off" }
        let s = config.downtimeSchedule
        let fmt = { (h: Int, m: Int) -> String in
            let suffix = h >= 12 ? "PM" : "AM"
            let hr = h == 0 ? 12 : (h > 12 ? h - 12 : h)
            return String(format: "%d:%02d %@", hr, m, suffix)
        }
        return "\(fmt(s.startHour, s.startMinute)) – \(fmt(s.endHour, s.endMinute))"
    }
}

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
