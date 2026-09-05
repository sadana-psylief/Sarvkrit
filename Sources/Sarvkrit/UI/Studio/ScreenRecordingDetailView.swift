import SwiftUI

/// The Screen Recording pane in the window.
struct ScreenRecordingDetailView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var feature: ScreenRecordingFeature

    var body: some View {
        Form {
            Section {
                Toggle("Enable", isOn: app.binding(for: feature))
            } header: {
                header
            }

            if let requirement = app.blockingRequirement(for: feature) {
                Section {
                    PermissionBanner(requirement: requirement) {
                        app.permissions.request(requirement)
                    }
                }
            }

            Section("Recording") {
                Picker("Frame rate", selection: Binding(
                    get: { feature.framesPerSecond },
                    set: { feature.framesPerSecond = $0 })) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                Toggle("Record system audio", isOn: Binding(
                    get: { feature.capturesSystemAudio },
                    set: { feature.capturesSystemAudio = $0 }))
                Toggle("Hide desktop icons", isOn: Binding(
                    get: { feature.hidesDesktopIcons },
                    set: { feature.hidesDesktopIcons = $0 }))
            }

            Section {
                Toggle("Show keystrokes", isOn: Binding(
                    get: { feature.showsKeystrokes },
                    set: { feature.showsKeystrokes = $0 }))
            } header: {
                Text("Keystrokes")
            } footer: {
                // Said plainly rather than buried: this is the one sub-toggle that starts watching
                // the keyboard, and it should be a decision rather than a discovery.
                Text("Off until you ask for it. Needs Accessibility, records the keys you press "
                     + "as labels rather than as text, and never records anything typed into a "
                     + "password field.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ForEach(RecordingAction.allCases) { action in
                    LabeledContent(action.title) {
                        Text(action.defaultShortcut.displayString)
                            .font(.system(size: Theme.Typography.body, design: .rounded))
                            .foregroundStyle(feature.failedRegistrations.contains(action)
                                             ? Color.orange : .secondary)
                    }
                }
                if !feature.failedRegistrations.isEmpty {
                    Text("Something else on this Mac already owns the ones in orange.")
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Section("How it works") {
                Text(feature.details)
                    .font(.system(size: Theme.Typography.body))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            FeatureIconTile(symbolName: feature.symbolName, isOn: app.isEnabled(feature))
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.system(size: Theme.Typography.title, weight: .semibold))
                Text(feature.summary)
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, Theme.Space.sm)
    }
}
