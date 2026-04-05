import SwiftUI

@MainActor
class AdminViewModel: ObservableObject {
    @Published var users: [ManagedUser] = []
    @Published var isLoading = false

    private let dbURL = "https://applerestrictions-default-rtdb.firebaseio.com"

    func loadUsers(idToken: String) async {
        isLoading = true
        guard let url = URL(string: "\(dbURL)/users.json?auth=\(idToken)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            users = dict.compactMap { uid, val in
                guard let userNode = val as? [String: Any],
                      let info = userNode["info"] as? [String: Any],
                      let email = info["email"] as? String else { return nil }
                return ManagedUser(
                    uid: uid,
                    email: email,
                    deviceName: info["deviceName"] as? String ?? "Unknown Device",
                    isOnline: info["isOnline"] as? Bool ?? false,
                    lastSeen: info["lastSeen"] as? String ?? ""
                )
            }.sorted { $0.email < $1.email }
        }
        isLoading = false
    }

    func sendCommand(_ type: RemoteCommand.CommandType, toUID uid: String, idToken: String) async {
        let cmd = RemoteCommand(type: type)
        guard let encoded = try? JSONEncoder().encode(cmd),
              let dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let url = URL(string: "\(dbURL)/users/\(uid)/commands.json?auth=\(idToken)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: dict)
        _ = try? await URLSession.shared.data(for: req)
    }
}

struct AdminDashboardView: View {
    @EnvironmentObject var auth: FirebaseAuthService
    @StateObject private var vm = AdminViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading users...")
                } else if vm.users.isEmpty {
                    ContentUnavailableView(
                        "No Users Yet",
                        systemImage: "person.2.slash",
                        description: Text("Add users in Firebase Console under Authentication.")
                    )
                } else {
                    List(vm.users) { user in
                        NavigationLink {
                            AdminUserControlView(user: user)
                                .environmentObject(auth)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(user.isOnline ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.email)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(user.deviceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if user.isOnline {
                                    Text("Online")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Managed Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task {
                    let token = await auth.freshToken() ?? ""
                    await vm.loadUsers(idToken: token)
                } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                }
            }
            .task {
                let token = await auth.freshToken() ?? ""
                await vm.loadUsers(idToken: token)
            }
        }
    }
}

struct AdminUserControlView: View {
    let user: ManagedUser
    @EnvironmentObject var auth: FirebaseAuthService
    @StateObject private var vm = AdminViewModel()
    @State private var showConfirm = false
    @State private var pendingCommand: RemoteCommand.CommandType?
    @State private var sent = false

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "iphone")
                        .font(.largeTitle)
                        .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                    VStack(alignment: .leading) {
                        Text(user.email)
                            .font(.headline)
                        Text(user.deviceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Circle()
                                .fill(user.isOnline ? .green : .gray)
                                .frame(width: 8, height: 8)
                            Text(user.isOnline ? "Online" : "Offline")
                                .font(.caption)
                                .foregroundStyle(user.isOnline ? .green : .secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Quick Commands") {
                CommandRow(icon: "lock.fill", label: "Lock All Apps", color: .red) {
                    send(.lockDevice)
                }
                CommandRow(icon: "lock.open.fill", label: "Unlock All Apps", color: .green) {
                    send(.unlockAll)
                }
                CommandRow(icon: "arrow.triangle.2.circlepath", label: "Refresh Settings", color: .blue) {
                    send(.refreshSettings)
                }
            }

            Section("Content Controls") {
                CommandRow(icon: "shield.fill", label: "Apply App Restrictions", color: .orange) {
                    send(.updateBlockedApps)
                }
                CommandRow(icon: "moon.fill", label: "Apply Downtime Schedule", color: .purple) {
                    send(.updateDowntime)
                }
                CommandRow(icon: "timer", label: "Apply Time Limits", color: .teal) {
                    send(.updateTimeLimits)
                }
            }

            if sent {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Command sent successfully")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .navigationTitle(user.email.components(separatedBy: "@").first ?? user.email)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send(_ type: RemoteCommand.CommandType) {
        Task {
            let token = await auth.freshToken() ?? ""
            await vm.sendCommand(type, toUID: user.uid, idToken: token)
            sent = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            sent = false
        }
    }
}

struct CommandRow: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ManagedUser: Identifiable {
    let uid: String
    let email: String
    let deviceName: String
    let isOnline: Bool
    let lastSeen: String
    var id: String { uid }
}
