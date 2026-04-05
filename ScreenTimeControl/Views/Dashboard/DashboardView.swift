import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @EnvironmentObject var syncService: RemoteSyncService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    restrictionsSummary
                    syncStatusCard
                }
                .padding()
            }
            .navigationTitle("B-SAFE")
            .refreshable {
                await syncService.manualSync()
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: settingsManager.isDowntimeActive ? "moon.fill" : "sun.max.fill")
                    .font(.title2)
                    .foregroundStyle(settingsManager.isDowntimeActive ? .purple : .orange)

                VStack(alignment: .leading) {
                    Text(settingsManager.isDowntimeActive ? "Downtime Active" : "Normal Mode")
                        .font(.headline)
                    Text(settingsManager.isDowntimeActive
                         ? "Restricted apps are blocked"
                         : "All allowed apps are accessible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var restrictionsSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Restrictions")
                .font(.headline)

            VStack(spacing: 8) {
                #if targetEnvironment(simulator)
                RestrictionRow(
                    icon: "app.badge", title: "Blocked Apps",
                    value: "\(settingsManager.blockedAppCount) apps",
                    isActive: settingsManager.blockedAppCount > 0)
                RestrictionRow(
                    icon: "square.grid.2x2", title: "Blocked Categories",
                    value: "\(settingsManager.blockedCategoryCount) categories",
                    isActive: settingsManager.blockedCategoryCount > 0)
                #else
                RestrictionRow(
                    icon: "app.badge", title: "Blocked Apps",
                    value: "\(settingsManager.selectedAppsToBlock.applicationTokens.count) apps",
                    isActive: !settingsManager.selectedAppsToBlock.applicationTokens.isEmpty)
                RestrictionRow(
                    icon: "square.grid.2x2", title: "Blocked Categories",
                    value: "\(settingsManager.selectedAppsToBlock.categoryTokens.count) categories",
                    isActive: !settingsManager.selectedAppsToBlock.categoryTokens.isEmpty)
                #endif

                RestrictionRow(
                    icon: "moon.zzz.fill", title: "Downtime",
                    value: settingsManager.configuration.downtimeEnabled
                        ? "\(formatTime(settingsManager.configuration.downtimeSchedule.startHour, settingsManager.configuration.downtimeSchedule.startMinute)) - \(formatTime(settingsManager.configuration.downtimeSchedule.endHour, settingsManager.configuration.downtimeSchedule.endMinute))"
                        : "Off",
                    isActive: settingsManager.configuration.downtimeEnabled)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote Sync")
                .font(.headline)

            HStack {
                Circle()
                    .fill(syncService.isOnline ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(syncService.isOnline ? "Connected" : "Offline")
                    .font(.subheadline)
                Spacer()
                if let lastSync = syncService.lastSyncDate {
                    Text("Last sync: \(lastSync, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = syncService.syncError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatTime(_ hour: Int, _ minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct RestrictionRow: View {
    let icon: String
    let title: String
    let value: String
    let isActive: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(isActive ? .blue : .gray)
                .frame(width: 24)
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(isActive ? .primary : .secondary)
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }
}
