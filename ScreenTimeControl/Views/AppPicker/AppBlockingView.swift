import SwiftUI

#if !targetEnvironment(simulator)
import FamilyControls
#endif

struct AppBlockingView: View {
    @State private var showAppPicker = false
    @State private var showAlwaysAllowedPicker = false

    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

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

                    #if targetEnvironment(simulator)
                    if settingsManager.blockedAppCount > 0 {
                        HStack {
                            Image(systemName: "app.fill")
                            Text("\(settingsManager.blockedAppCount) apps selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                    #else
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
                    #endif
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
                } header: {
                    Text("Always Allowed")
                } footer: {
                    Text("These apps will remain accessible even during downtime.")
                }
            }
            .navigationTitle("Block Apps")
            #if targetEnvironment(simulator)
            .sheet(isPresented: $showAppPicker) {
                SimulatorAppPickerView(title: "Select Apps to Block") {
                    settingsManager.blockedAppCount = 5
                    settingsManager.blockedCategoryCount = 2
                }
            }
            .sheet(isPresented: $showAlwaysAllowedPicker) {
                SimulatorAppPickerView(title: "Always Allowed Apps") {}
            }
            #else
            .familyActivityPicker(
                isPresented: $showAppPicker,
                selection: $settingsManager.selectedAppsToBlock
            )
            .familyActivityPicker(
                isPresented: $showAlwaysAllowedPicker,
                selection: $settingsManager.selectedAppsAlwaysAllowed
            )
            #endif
        }
    }
}

#if targetEnvironment(simulator)
/// Stand-in picker for Simulator since FamilyActivityPicker is device-only
struct SimulatorAppPickerView: View {
    let title: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let fakeApps = [
        ("Safari", "safari"), ("Instagram", "camera.filters"),
        ("YouTube", "play.rectangle.fill"), ("TikTok", "music.note"),
        ("Snapchat", "message.fill"), ("Twitter", "bird"),
        ("Messages", "message.fill"), ("Mail", "envelope.fill"),
    ]

    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Apps") {
                    ForEach(fakeApps, id: \.0) { app in
                        Button {
                            if selected.contains(app.0) {
                                selected.remove(app.0)
                            } else {
                                selected.insert(app.0)
                            }
                        } label: {
                            HStack {
                                Image(systemName: app.1)
                                    .frame(width: 30)
                                Text(app.0)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(app.0) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Categories") {
                    ForEach(["Social", "Entertainment", "Games", "Productivity"], id: \.self) { cat in
                        Button {
                            if selected.contains(cat) {
                                selected.remove(cat)
                            } else {
                                selected.insert(cat)
                            }
                        } label: {
                            HStack {
                                Text(cat).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(cat) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif
