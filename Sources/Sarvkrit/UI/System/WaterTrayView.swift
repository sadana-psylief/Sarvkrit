import SwiftUI

/// The Water panel: where you are today, and one click to log a drink.
///
/// Logging is the thing you open this for, so the sizes are full-width menu rows rather than small
/// buttons — a target you can hit without looking. Everything you set once (the goal, the hours,
/// the quiet rules) lives in the detail pane.
///
/// Logging works with reminders switched off. Some people want the count and not the nudges, and a
/// tracker that refused to track until it was also allowed to interrupt would be a strange deal.
struct WaterTrayView: View {
    @ObservedObject var feature: WaterReminderFeature
    @EnvironmentObject private var app: AppState

    /// The caption names times ("snoozed until 15:40") and has to roll over on its own.
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            SettingsModule {
                SettingsRow(
                    symbolName: feature.thirst == .none ? "drop" : feature.thirst.symbolName,
                    title: "Water Reminder",
                    caption: caption,
                    isHighlighted: feature.isRunning && feature.thirst != .none
                ) {
                    Toggle("", isOn: app.binding(for: feature))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                ModuleSeparator()

                progress
            }

            SettingsModule {
                ForEach(feature.quickSizes, id: \.name) { size in
                    MenuActionRow(title: size.name, shortcut: feature.unit.format(size.milliliters)) {
                        feature.logDrink(milliliters: size.milliliters)
                    }
                }
                if let last = feature.todaysEntries.last(where: { $0.id == feature.log.lastLogged?.id }) {
                    MenuActionRow(
                        title: "Undo \(feature.unit.format(last.milliliters))",
                        shortcut: last.date.formatted(date: .omitted, time: .shortened)
                    ) { feature.undoLast() }
                }
                if feature.isRunning, !feature.goalMet {
                    if feature.isSnoozed || feature.isSilencedToday {
                        MenuActionRow(title: "Resume reminders") { feature.resumeReminders() }
                    } else {
                        MenuActionRow(title: "Snooze for an hour") { feature.snooze(for: 60 * 60) }
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    /// "1.1 L of 2 L" beside a meter. Not a `StatRow`: its fixed value column is sized for "42%",
    /// and "1.25 L of 2 L" or "37.2 fl oz" would be truncated.
    private var progress: some View {
        let consumed = feature.consumedToday
        let goal = feature.goalMilliliters
        let text = "\(feature.unit.format(consumed)) of \(feature.unit.format(goal))"
        return HStack(spacing: Theme.Space.md) {
            Text("Today")
                .font(.system(size: Theme.Typography.body))
            MeterBar(value: Double(consumed), ceiling: Double(goal))
                .frame(maxWidth: .infinity)
            Text(text)
                .font(.system(size: Theme.Typography.body, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.panelRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today, \(text)")
    }

    /// What the reminder is doing, in a few words. Never a scolding — "behind" is said once, as a
    /// fact, and never in red.
    private var caption: String {
        _ = now
        guard feature.isRunning else { return "Reminders off · logging still works" }
        if feature.goalMet { return "Today's goal reached" }
        if feature.isSilencedToday { return "Paused until tomorrow" }
        if feature.isSnoozed, let until = feature.snoozedUntil {
            return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if feature.thirst != .none { return "Time for a glass" }
        return feature.consumedToday >= feature.expectedByNow ? "On pace" : "A little behind"
    }
}
