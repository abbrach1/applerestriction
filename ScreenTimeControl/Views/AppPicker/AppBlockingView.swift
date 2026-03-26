import SwiftUI
import FamilyControls

struct AppBlockingView: View {
    @EnvironmentObject var settingsManager: ScreenTimeSettingsManager
    @State private var showAppPicker = false
    @State private var showAlwaysAllowedPicker = false

    var body: some View {
        NavigationStack {
            List {
                // Blocked Apps Section
                Section {
                    Button {
                        showAppPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Select Apps to Block")
                        }
                    }

                    if !settingsManager.selectedAppsToBlock.applicationTokens.isEmpty {
                        HStack {
                            Image(systemName: "app.fill")
                            Text("\(settingsManager.selectedAppsToBlock.applicationTokens.count) apps selected")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !settingsManager.selectedAppsToBlock.categoryTokens.isEmpty {
                        HStack {
                            Image(systemName: "square.grid.2x2.fill")
                            Text("\(settingsManager.selectedAppsToBlock.categoryTokens.count) categories selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Blocked Apps & Categories")
                } footer: {
                    Text("Selected apps will be blocked and show a shield screen when opened.")
                }

                // Apply / Clear Section
                Section {
                    Button {
                        settingsManager.applyAppRestrictions()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("Apply Restrictions")
                        }
                    }

                    Button(role: .destructive) {
                        settingsManager.clearAppRestrictions()
                    } label: {
                        HStack {
                            Image(systemName: "xmark.shield.fill")
                            Text("Clear All Restrictions")
                        }
                    }
                }

                // Always Allowed Section
                Section {
                    Button {
                        showAlwaysAllowedPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "star.circle.fill")
                                .foregroundStyle(.yellow)
                            Text("Always Allowed Apps")
                        }
                    }

                    if !settingsManager.selectedAppsAlwaysAllowed.applicationTokens.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("\(settingsManager.selectedAppsAlwaysAllowed.applicationTokens.count) apps always allowed")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Always Allowed")
                } footer: {
                    Text("These apps will remain accessible even during downtime.")
                }
            }
            .navigationTitle("Block Apps")
            .familyActivityPicker(
                isPresented: $showAppPicker,
                selection: $settingsManager.selectedAppsToBlock
            )
            .familyActivityPicker(
                isPresented: $showAlwaysAllowedPicker,
                selection: $settingsManager.selectedAppsAlwaysAllowed
            )
        }
    }
}
