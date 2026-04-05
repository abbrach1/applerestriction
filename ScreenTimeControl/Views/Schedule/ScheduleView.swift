import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    @State private var downtimeEnabled: Bool = false
    @State private var startTime = Calendar.current.date(
        from: DateComponents(hour: 22, minute: 0)
    ) ?? Date()
    @State private var endTime = Calendar.current.date(
        from: DateComponents(hour: 7, minute: 0)
    ) ?? Date()
    @State private var selectedDays: Set<Int> = Set(1...7)

    private let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        NavigationStack {
            Form {
                // Downtime Toggle
                Section {
                    Toggle("Enable Downtime", isOn: $downtimeEnabled)
                        .onChange(of: downtimeEnabled) { _, newValue in
                            if newValue {
                                applySchedule()
                            } else {
                                settingsManager.disableDowntime()
                            }
                        }
                } footer: {
                    Text("During downtime, only apps you choose to allow will be available.")
                }

                if downtimeEnabled {
                    // Time Selection
                    Section("Schedule") {
                        DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                        DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                    }

                    // Day Selection
                    Section("Active Days") {
                        ForEach(0..<7, id: \.self) { index in
                            let dayNumber = index + 1
                            Button {
                                if selectedDays.contains(dayNumber) {
                                    selectedDays.remove(dayNumber)
                                } else {
                                    selectedDays.insert(dayNumber)
                                }
                            } label: {
                                HStack {
                                    Text(dayNames[index])
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedDays.contains(dayNumber) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }

                    // Apply Button
                    Section {
                        Button {
                            applySchedule()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Apply Schedule")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }

                // Time Limits
                Section {
                    NavigationLink {
                        TimeLimitsView()
                    } label: {
                        HStack {
                            Image(systemName: "timer")
                                .foregroundStyle(.orange)
                            Text("App Time Limits")
                        }
                    }
                } header: {
                    Text("Time Limits")
                } footer: {
                    Text("Set daily time limits for specific apps or categories.")
                }
            }
            .navigationTitle("Schedule")
            .onAppear {
                loadCurrentSchedule()
            }
        }
    }

    private func loadCurrentSchedule() {
        let schedule = settingsManager.configuration.downtimeSchedule
        downtimeEnabled = settingsManager.configuration.downtimeEnabled
        selectedDays = schedule.activeDays

        startTime = Calendar.current.date(
            from: DateComponents(hour: schedule.startHour, minute: schedule.startMinute)
        ) ?? startTime

        endTime = Calendar.current.date(
            from: DateComponents(hour: schedule.endHour, minute: schedule.endMinute)
        ) ?? endTime
    }

    private func applySchedule() {
        let startComponents = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let endComponents = Calendar.current.dateComponents([.hour, .minute], from: endTime)

        let schedule = DowntimeSchedule(
            startHour: startComponents.hour ?? 22,
            startMinute: startComponents.minute ?? 0,
            endHour: endComponents.hour ?? 7,
            endMinute: endComponents.minute ?? 0,
            activeDays: selectedDays
        )

        settingsManager.setDowntimeSchedule(schedule)
    }
}

struct TimeLimitsView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @State private var timeLimitMinutes: Double = 60
    @State private var showAppPicker = false

    var body: some View {
        Form {
            Section("Daily Time Limit") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Limit: \(Int(timeLimitMinutes)) minutes")
                        .font(.headline)

                    Slider(value: $timeLimitMinutes, in: 5...480, step: 5)

                    HStack {
                        Text("5 min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("8 hours")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    settingsManager.setTimeLimit(
                        minutes: Int(timeLimitMinutes),
                        for: "daily.limit"
                    )
                } label: {
                    HStack {
                        Spacer()
                        Text("Set Time Limit")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            } footer: {
                Text("When the time limit is reached, selected apps will be blocked for the rest of the day.")
            }
        }
        .navigationTitle("Time Limits")
    }
}
