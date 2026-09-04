import SwiftUI

/// Sliders for whatever is making sound: the top half of the Sound panel.
///
/// It used to sit *under* the feature's own switch inside that switch's card, which is why it began
/// with a `ModuleSeparator` and supplied no card of its own — it was a sibling row type, borrowing
/// the module around it. It is one of two things on a panel now, so it owns its card and starts
/// with content rather than a hairline dividing it from nothing.
struct VolumeMixerTrayView: View {
    @ObservedObject var feature: VolumeMixerFeature

    /// What each app was at before it was muted, so unmuting restores it rather than guessing at
    /// full volume. Panel-lifetime only: mute is a level of zero and persists as one, and
    /// remembering the pre-mute level across launches would be a second kind of state for a
    /// button.
    @State private var levelBeforeMute: [String: Float] = [:]

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
                .frame(height: CGFloat(feature.processes.count) * Theme.Metrics.panelRowHeight)
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
        let level = feature.level(for: process.bundleID)
        let isBoosted = level > 1

        return HStack(spacing: Theme.Space.sm) {
            icon(for: process)

            Text(process.name)
                .font(.system(size: Theme.Typography.body))
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(feature.level(for: process.bundleID)) },
                    set: { feature.setLevel(Float($0), for: process.bundleID) }
                ),
                in: Double(MixerLevels.minimum)...Double(MixerLevels.maximum)
            )
            .controlSize(.mini)
            // Orange past unity, the one place in the app where the accent colour marks a state
            // rather than a selection: everything above 100% is Sarvkrit adding gain that was not
            // in the original, and the slider should say so without a label.
            .tint(isBoosted ? .orange : .accentColor)

            percentage(level, isBoosted: isBoosted)
            muteButton(for: process, level: level)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.panelRowHeight)
    }

    private func icon(for process: AudioProcess) -> some View {
        Group {
            if let icon = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: process.bundleID)
                .map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func percentage(_ level: Float, isBoosted: Bool) -> some View {
        HStack(spacing: 1) {
            if isBoosted {
                Image(systemName: "bolt.fill").font(.system(size: 9))
            }
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: Theme.Typography.caption, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(isBoosted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        // Wide enough for "⚡200%", so the slider doesn't shorten as an app is boosted.
        .frame(width: 46, alignment: .trailing)
    }

    /// Mute is a level of zero, so there is nothing extra to persist — but the level it came *from*
    /// is worth keeping for the length of the panel, or unmuting would have to guess and would
    /// throw away a carefully set 40%.
    private func muteButton(for process: AudioProcess, level: Float) -> some View {
        Button {
            if level == 0 {
                feature.setLevel(levelBeforeMute[process.bundleID] ?? 1, for: process.bundleID)
                levelBeforeMute[process.bundleID] = nil
            } else {
                levelBeforeMute[process.bundleID] = level
                feature.setLevel(0, for: process.bundleID)
            }
        } label: {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(level == 0 ? AnyShapeStyle(Color.orange)
                                            : AnyShapeStyle(.secondary))
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel(level == 0 ? "Unmute \(process.name)" : "Mute \(process.name)")
    }
}
