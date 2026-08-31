import AppKit
import SwiftUI

struct VolumeMixerDetailView: View {
    @ObservedObject var feature: VolumeMixerFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Volume Mixer", isOn: app.binding(for: feature))
            } footer: {
                Text("Give each app its own volume. Apps appear while they're playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if feature.permissionLooksDenied {
                Section {
                    Label(
                        "Sarvkrit doesn't seem to be allowed to record system audio, so it can't "
                            + "change app volumes.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("Open System Settings") {
                        app.permissions.openSystemSettings(for: .audioCapture)
                    }
                } footer: {
                    // Worth explaining, because it's unusual and otherwise reads as a vague app bug.
                    Text("""
                        macOS gives no way to ask whether this permission was granted, and refusing \
                        it doesn't produce an error — everything reports success and the audio \
                        simply arrives empty. Sarvkrit works this out by noticing it has been \
                        handed nothing but silence, so it can take a few seconds to appear.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if feature.processes.isEmpty {
                    Text("Nothing is playing.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(feature.processes) { process in
                        LabeledContent(process.name) {
                            HStack(spacing: Theme.Space.sm) {
                                Slider(
                                    value: Binding(
                                        get: { Double(feature.level(for: process.bundleID)) },
                                        set: { feature.setLevel(Float($0), for: process.bundleID) }
                                    ),
                                    in: 0...1
                                )
                                .frame(width: 140)
                                Text("\(Int(feature.level(for: process.bundleID) * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                }
            } header: {
                Text("Playing now")
            }

            Section {
                if feature.customisedBundleIDs.isEmpty {
                    Text("You haven't changed any app's volume.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(feature.customisedBundleIDs, id: \.self) { bundleID in
                        LabeledContent(displayName(bundleID)) {
                            HStack(spacing: Theme.Space.sm) {
                                Text("\(Int(feature.level(for: bundleID) * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button("Reset") { feature.resetLevel(for: bundleID) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    Button("Reset every app", role: .destructive) { feature.resetAllLevels() }
                }
            } header: {
                Text("Remembered")
            } footer: {
                // Every app that's been turned down, listed — so nothing is quietly attenuated in a
                // place the user can't find weeks later.
                Text("""
                    Volumes are remembered by app, so they survive quitting and restarting. Every \
                    app you've changed is listed here, and only apps you've actually turned down \
                    are routed through Sarvkrit at all.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { feature.refresh() }
    }

    private func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
