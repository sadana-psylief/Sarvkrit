import SwiftUI

/// Keep Awake's panel in the menu bar: what it is doing, and the two switches worth reaching for.
///
/// The only panel shown while its feature is switched off, because here the switch *is* the
/// feature — see `Feature.panelIsItsOwnSwitch`. Everything finer grained (the duration picker,
/// keeping the display on) stays in the detail pane: this is the thing you open the menu to do,
/// and the rest is a preference you set once.
struct KeepAwakeTrayView: View {
    @ObservedObject var feature: KeepAwakeFeature
    @EnvironmentObject private var app: AppState

    /// The remaining-time line counts down, and nothing else republishes once a second.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsModule {
            SettingsRow(
                symbolName: feature.iconState.symbolName,
                title: "Keep Awake",
                caption: caption,
                isHighlighted: feature.isRunning
            ) {
                Toggle("", isOn: app.binding(for: feature))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            ModuleSeparator()

            SettingsRow(
                symbolName: "laptopcomputer",
                title: "Keep going with the lid closed",
                caption: feature.lidClosed
                    ? "Sleep fully disabled. Mind the power"
                    : "Needs your password — it changes a system setting",
                isHighlighted: feature.lidClosedActive
            ) {
                Toggle("", isOn: Binding(
                    get: { feature.lidClosed },
                    set: { feature.lidClosed = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // Off while Keep Awake is off: the lid setting only means anything alongside the
                // assertion, and offering it alone would ask for a password to do nothing.
                .disabled(!feature.isRunning)
            }
        }
        .onReceive(tick) { now = $0 }
    }

    /// Says what the Mac is actually doing, not what the switch is set to — those differ while a
    /// timer is running, and the difference is the whole reason someone opens this panel.
    private var caption: String {
        guard feature.isRunning else { return "Your Mac sleeps normally" }
        guard let remaining = feature.remainingTime else { return "Active until you turn it off" }
        return "Active for another \(format(remaining))"
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total % 60)s"
    }
}
