import CoreAudio
import SwiftUI

struct SoundDetailView: View {
    @ObservedObject var feature: OutputSwitcherFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Audio Devices", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Pick where your Mac plays sound and which microphone it listens with, from the \
                    menu bar rather than System Settings.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AudioDevice.Kind.allCases) { kind in
                Section {
                    Picker("Switch to automatically", selection: Binding(
                        get: { feature.preferredUID(for: kind) },
                        set: { feature.setPreferredUID($0, for: kind) }
                    )) {
                        Text("Don't switch").tag(String?.none)
                        Divider()
                        ForEach(feature.selectable(kind)) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    LabeledContent("Currently using") {
                        Text(currentName(kind))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(kind.title)
                }
            }

            Section {
                Toggle("Switch automatically when a preferred device connects", isOn: Binding(
                    get: { feature.autoSwitchEnabled },
                    set: { feature.autoSwitchEnabled = $0 }
                ))
                Toggle("Cycle output devices with ⌃⌥O", isOn: Binding(
                    get: { feature.cycleShortcutEnabled },
                    set: { feature.cycleShortcutEnabled = $0 }
                ))
            } header: {
                Text("Behaviour")
            } footer: {
                Text("""
                    Aggregate and virtual devices are left out of the lists. Those belong to other \
                    audio software, and switching your output to one is a good way to break \
                    whatever created it.

                    None of this needs any permission.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { feature.refresh() }
    }

    private func currentName(_ kind: AudioDevice.Kind) -> String {
        guard let id = feature.current(kind),
              let device = feature.devices.first(where: { $0.id == id })
        else { return "—" }
        return device.name
    }
}
