import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "shield.checkered")
                }

            AppBlockingView()
                .tabItem {
                    Label("Block Apps", systemImage: "shield.fill")
                }

            ScheduleView()
                .tabItem {
                    Label("Schedule", systemImage: "clock.fill")
                }

            RemoteControlView()
                .tabItem {
                    Label("Remote", systemImage: "antenna.radiowaves.left.and.right")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .tint(Color(red: 0, green: 0.4, blue: 0.15))
    }
}
