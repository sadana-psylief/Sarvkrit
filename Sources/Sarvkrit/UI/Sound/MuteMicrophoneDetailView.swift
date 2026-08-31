import SwiftUI

struct MuteMicrophoneDetailView: View {
    @ObservedObject var feature: MuteMicrophoneFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Mute Microphone", isOn: app.binding(for: feature))
            } footer: {
                Text("Muting happens at the device, so nothing can hear it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if feature.isUnsupported {
                    // Said rather than offering a switch that silently does nothing.
                    Label(
                        "This microphone can't be muted by Sarvkrit — it supports neither a mute "
                            + "control nor an input level.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                } else {
                    Toggle("Microphone muted", isOn: Binding(
                        get: { feature.isMuted },
                        set: { feature.setMuted($0) }
                    ))
                }
                LabeledContent("Microphone") {
                    Text(feature.deviceName ?? "None")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Now")
            }

            Section {
                Toggle("Toggle with ⌃⌥M", isOn: Binding(
                    get: { feature.shortcutEnabled },
                    set: { feature.shortcutEnabled = $0 }
                ))
            } header: {
                Text("Shortcut")
            } footer: {
                Text("""
                    The menu bar icon changes while the microphone is muted, so you can see it \
                    without opening anything.

                    Apps with their own mute button — Zoom, Teams, Meet — will still show \
                    themselves as unmuted. Theirs and this are two switches on the same wire, and \
                    Sarvkrit can't reach into theirs.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
