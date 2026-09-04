import SwiftUI

/// Sliders for whatever is making sound: the top half of the Sound panel.
///
/// It used to sit *under* the feature's own switch inside that switch's card, which is why it began
/// with a `ModuleSeparator` and supplied no card of its own — it was a sibling row type, borrowing
/// the module around it. It is one of two things on a panel now, so it owns its card and starts
/// with content rather than a hairline dividing it from nothing.
struct VolumeMixerTrayView: View {
    @ObservedObject var feature: VolumeMixerFeature

    var body: some View {
        SettingsModule {
            if feature.permissionLooksDenied {
                notice
            } else if feature.processes.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(feature.processes) { process in
                            row(process)
                        }
                    }
                }
                // Grows with the app count. It used to be capped at 132pt because a panel whose
                // content changed height while open drifted away from the menu bar — and this list
                // changes on its own every couple of seconds. `MenuBarWindowAnchor` holds the
                // panel's top edge now, so the cap was buying nothing. The `ScrollView` stays: it
                // costs nothing and is the only thing standing between an implausible number of
                // apps playing at once and a panel taller than the screen.
                .frame(height: CGFloat(feature.processes.count) * 34)
            }
        }
    }

    private var empty: some View {
        Text("Nothing playing")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.rowInset)
            .frame(height: 30)
    }

    private var notice: some View {
        // Denial is silent — every Core Audio call still reports success — so this is the only
        // moment the user can be told anything at all.
        Label(
            "Allow Sarvkrit to record system audio in System Settings to set app volumes.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .padding(.horizontal, Theme.Metrics.rowInset)
        .padding(.vertical, Theme.Space.sm)
    }

    private func row(_ process: AudioProcess) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let icon = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: process.bundleID)
                .map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app").frame(width: 16)
            }

            Text(process.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(feature.level(for: process.bundleID)) },
                    set: { feature.setLevel(Float($0), for: process.bundleID) }
                ),
                in: 0...1
            )
            .controlSize(.mini)

            Text("\(Int(feature.level(for: process.bundleID) * 100))")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: 34)
    }
}
