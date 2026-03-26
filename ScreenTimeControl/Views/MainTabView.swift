import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent")
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
    }
}
