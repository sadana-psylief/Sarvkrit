import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmHideIcon = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $app.launchAtLogin)
            } footer: {
                Text("Registers the copy of Sarvkrit you launched. Move it to your Applications folder first so it still starts after you clean up your Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Menu Bar Icon", isOn: Binding(
                    get: { app.showMenuBarIcon },
                    set: { newValue in
                        // Hiding the icon in an LSUIElement app removes the only visible way
                        // back in, so it gets a confirmation. Turning it back on doesn't.
                        if newValue { app.showMenuBarIcon = true } else { confirmHideIcon = true }
                    }
                ))
            } footer: {
                Text("Features keep working while the icon is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Quit Sarvkrit") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Hide the menu bar icon?", isPresented: $confirmHideIcon) {
            Button("Hide Icon") { app.showMenuBarIcon = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sarvkrit will keep running with no icon. To get this window back, open Sarvkrit again from your Applications folder.")
        }
    }
}

struct AboutView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Bundle Identifier", value: Bundle.main.bundleIdentifier ?? "—")
                LabeledContent("Accessibility") {
                    Text(app.permissions.isTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(app.permissions.isTrusted ? Color.secondary : Color.orange)
                }
                LabeledContent("Screen Recording") {
                    Text(app.permissions.canCaptureScreen ? "Granted" : "Not granted")
                        .foregroundStyle(app.permissions.canCaptureScreen ? Color.secondary : Color.orange)
                }
            }
            Section {
                // Useful in a permissions app: TCC grants are keyed to the app's location and
                // signature, so "which copy is actually running?" is a real question.
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            } footer: {
                Text(Bundle.main.bundleURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }
}
