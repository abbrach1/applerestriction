import SwiftUI
import UIKit

struct ChildDeviceView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @EnvironmentObject var syncService: RemoteSyncService
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                // Device info card
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0, green: 0.4, blue: 0.15).opacity(0.12))
                            .frame(width: 100, height: 100)
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 48))
                            .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                    }

                    VStack(spacing: 6) {
                        Text(auth.currentUser?.email ?? "")
                            .font(.headline)
                        Text(UIDevice.current.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Protected by B-SAFE")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.1), in: Capsule())
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)

                // Last synced
                if let last = syncService.lastSyncDate {
                    Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Refresh button
                Button {
                    Task {
                        isRefreshing = true
                        await syncService.manualSync()
                        isRefreshing = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isRefreshing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRefreshing ? "Syncing..." : "Sync Settings Now")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(red: 0, green: 0.4, blue: 0.15))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isRefreshing)
                .padding(.horizontal)

                Spacer()

                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                }
                .font(.subheadline)
                .padding(.bottom)
            }
            .navigationTitle("B-SAFE")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
