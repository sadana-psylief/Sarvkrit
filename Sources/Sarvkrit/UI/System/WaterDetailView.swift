import Charts
import SwiftUI

struct WaterDetailView: View {
    @ObservedObject var feature: WaterReminderFeature
    @EnvironmentObject private var app: AppState

    /// For "I had one at lunch and forgot to log it".
    @State private var earlierTime = Date()
    @State private var earlierSize = 250

    var body: some View {
        Form {
            Section {
                Toggle("Water Reminder", isOn: app.binding(for: feature))
            } footer: {
                Text("Reminds you when you fall behind a steady pace toward your goal. Logging a drink resets the clock, so drinking early means no reminder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if feature.isRunning, feature.permission != .allowed {
                Section { permissionNotice }
            }

            today
            history
            goalAndSizes
            schedule
            quiet
        }
        .formStyle(.grouped)
        .navigationTitle("Water Reminder")
        .onAppear {
            feature.refreshPermission()
            earlierSize = feature.glassMilliliters
            earlierTime = feature.now
        }
    }

    // MARK: - Sections

    private var today: some View {
        Section {
            LabeledContent("So far") {
                Text("\(unit.format(feature.consumedToday)) of \(unit.format(feature.goalMilliliters))")
                    .monospacedDigit()
            }
            ForEach(feature.todaysEntries.reversed()) { entry in
                HStack {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(unit.format(entry.milliliters))
                    Spacer()
                    Button {
                        feature.remove(entry: entry.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(unit.format(entry.milliliters)) at \(entry.date.formatted(date: .omitted, time: .shortened))")
                }
            }
            HStack {
                DatePicker("Add one earlier", selection: $earlierTime,
                           in: feature.todayStart...max(feature.todayStart, feature.now),
                           displayedComponents: .hourAndMinute)
                Picker("", selection: $earlierSize) {
                    ForEach(feature.quickSizes, id: \.name) { size in
                        Text(unit.format(size.milliliters)).tag(size.milliliters)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add") { feature.logDrink(milliliters: earlierSize, at: earlierTime) }
            }
        } header: {
            Text("Today")
        }
    }

    private var history: some View {
        let days = feature.history(days: 14)
        let goal = unit.value(of: feature.goalMilliliters)
        return Section {
            // No colour for a day under the goal. A wall of red bars is how a tracker turns into a
            // thing you stop opening; the goal line already says everything a colour would.
            Chart {
                ForEach(days, id: \.day) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Drank", unit.value(of: day.milliliters)))
                    .foregroundStyle(Color.accentColor.gradient)
                }
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(SwiftUI.StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow).day())
                }
            }
            .frame(height: 140)
            .accessibilityLabel("Water drunk over the last 14 days")
        } header: {
            Text("Last two weeks")
        }
    }

    private var goalAndSizes: some View {
        Section {
            Picker("Units", selection: Binding(get: { feature.unit }, set: { feature.unit = $0 })) {
                ForEach(VolumeUnit.allCases) { Text($0.title).tag($0) }
            }
            volumeStepper("Daily goal", milliliters: Binding(
                get: { feature.goalMilliliters }, set: { feature.goalMilliliters = $0 }),
                range: 250...6_000, mlStep: 250, ozStep: 8)
            volumeStepper("Glass", milliliters: Binding(
                get: { feature.glassMilliliters }, set: { feature.glassMilliliters = $0 }),
                range: 25...2_000, mlStep: 25, ozStep: 1)
            volumeStepper("Bottle", milliliters: Binding(
                get: { feature.bottleMilliliters }, set: { feature.bottleMilliliters = $0 }),
                range: 25...2_000, mlStep: 25, ozStep: 1)
            Toggle("Custom size", isOn: Binding(
                get: { feature.customMilliliters > 0 },
                set: { feature.customMilliliters = $0 ? 750 : 0 }))
            if feature.customMilliliters > 0 {
                volumeStepper("Custom", milliliters: Binding(
                    get: { feature.customMilliliters }, set: { feature.customMilliliters = $0 }),
                    range: 25...2_000, mlStep: 25, ozStep: 1)
            }
        } header: {
            Text("Goal and Sizes")
        } footer: {
            Text("2 litres is a common starting point. Food and other drinks count toward what you need too, so treat the goal as a nudge, not a rule.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var schedule: some View {
        Section {
            DatePicker("Reminders from", selection: timeBinding(
                get: { feature.activeStartMinutes }, set: { feature.activeStartMinutes = $0 }),
                displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: timeBinding(
                get: { feature.activeEndMinutes }, set: { feature.activeEndMinutes = $0 }),
                displayedComponents: .hourAndMinute)
            if feature.activeEndMinutes <= feature.activeStartMinutes {
                Label("The end needs to be after the start. No reminders until it is.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("New day starts at", selection: Binding(
                get: { feature.dayStartHour }, set: { feature.dayStartHour = $0 })) {
                ForEach(0...8, id: \.self) { hour in
                    Text(hourLabel(hour)).tag(hour)
                }
            }
            Stepper(value: Binding(
                get: { feature.minimumGapMinutes }, set: { feature.minimumGapMinutes = $0 }),
                in: 15...240, step: 15) {
                spread("At most one reminder every", minutesLabel(feature.minimumGapMinutes))
            }
            Stepper(value: Binding(
                get: { feature.maximumGapMinutes }, set: { feature.maximumGapMinutes = $0 }),
                in: 15...240, step: 15) {
                spread("Remind anyway after", minutesLabel(feature.maximumGapMinutes))
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Drinks after midnight count toward the day before until the new day starts. \"Remind anyway\" applies even when you're ahead, so a good morning doesn't mean nothing until evening.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quiet: some View {
        Section {
            Toggle("Stay quiet during calls", isOn: Binding(
                get: { feature.quietInMeetings }, set: { feature.quietInMeetings = $0 }))
            Toggle("Stay quiet when you've stepped away", isOn: Binding(
                get: { feature.quietWhenIdle }, set: { feature.quietWhenIdle = $0 }))
        } header: {
            Text("Quiet Times")
        } footer: {
            Text("A call means the camera or microphone is in use. Stepped away means no typing or mouse for five minutes. Nothing pops up while the screen is locked, and Focus holds reminders back too. After a long break you get one reminder a few minutes after you return, never a backlog.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label(feature.permission == .denied
                  ? "Notifications are off for Sarvkrit"
                  : "Sarvkrit hasn't been allowed to send notifications yet",
                  systemImage: "bell.slash")
                .font(.subheadline.weight(.semibold))
            Text("Reminders still show in the menu bar icon, but nothing will pop up.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if feature.permission == .denied {
                Button("Open Notification Settings") { SystemNotifications.openSettings() }
            } else {
                Button("Allow Notifications") { feature.requestPermission() }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    // MARK: - Helpers

    private var unit: VolumeUnit { feature.unit }

    /// A stepper in whatever unit is showing, storing millilitres underneath.
    private func volumeStepper(
        _ title: String, milliliters: Binding<Int>, range: ClosedRange<Int>, mlStep: Int, ozStep: Int
    ) -> some View {
        let step = unit == .milliliters
            ? Double(mlStep)
            : Double(ozStep) * VolumeUnit.millilitersPerOunce
        return Stepper {
            spread(title, unit.format(milliliters.wrappedValue))
        } onIncrement: {
            milliliters.wrappedValue = min(range.upperBound, Int((Double(milliliters.wrappedValue) + step).rounded()))
        } onDecrement: {
            milliliters.wrappedValue = max(range.lowerBound, Int((Double(milliliters.wrappedValue) - step).rounded()))
        }
    }

    /// Minutes-after-midnight as a `Date` today, for a time-only `DatePicker`.
    private func timeBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: get(), to: Calendar.current.startOfDay(for: Date()))
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            })
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return hour == 0 ? "Midnight" : date.formatted(date: .omitted, time: .shortened)
    }

    /// Title left, value right, like every other row in the form. A `LabeledContent` inside a
    /// `Stepper` label sits its value right up against the title instead.
    private func spread(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func minutesLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
