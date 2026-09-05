import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmHideIcon = false

    var body: some View {
        Form {
            // First in the pane, above Launch at Login: it is the only thing here that is
            // time-sensitive, and the banner in the menu bar sends people straight to it.
            if case .available(let release) = app.updates.state {
                Section {
                    UpdateNoticeView(release: release) { app.updates.skip(release) }
                }
            }

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
                Toggle("Check for Updates Automatically", isOn: $app.automaticUpdateChecks)
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(updateFooter)
                    if UpdateCheckAgent.needsApproval {
                        // Registering again would do nothing — only the user can undo this — so
                        // the honest move is to say where it was turned off and offer the way back.
                        Button("Open Login Items") { UpdateCheckAgent.openLoginItemsSettings() }
                            .buttonStyle(.link)
                    }
                }
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

extension GeneralSettingsView {
    /// Says what actually happens, because the app's whole pitch is that it doesn't phone home.
    /// The check is a separate launchd job precisely so it can be described in one sentence and
    /// switched off in a place that isn't Sarvkrit's own settings.
    var updateFooter: String {
        if UpdateCheckAgent.needsApproval {
            return "Turned off in System Settings. Sarvkrit asks GitHub once a day whether there's a newer version, and sends nothing about you or your Mac."
        }
        if !app.automaticUpdateChecks {
            return "Sarvkrit is not checking for updates. When this is on it asks GitHub once a day whether there's a newer version, and sends nothing about you or your Mac."
        }
        return "Asks GitHub once a day whether there's a newer version, and sends nothing about you or your Mac. It runs as a background item you can also switch off in System Settings → General → Login Items. \(lastCheckedDescription)"
    }

    private var lastCheckedDescription: String {
        guard let lastChecked = app.updates.lastChecked else {
            return app.updates.lastFailure == nil
                ? "It hasn't run yet."
                : "The last attempt couldn't reach GitHub."
        }
        let formatted = lastChecked.formatted(date: .abbreviated, time: .shortened)
        return app.updates.isStale
            ? "Last managed to check on \(formatted)."
            : "Last checked \(formatted)."
    }
}

struct AboutView: View {
    @EnvironmentObject private var app: AppState
    @State private var isChecking = false

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
                LabeledContent("Updates") {
                    HStack(spacing: Theme.Space.sm) {
                        Text(updateStatus)
                            .foregroundStyle(.secondary)
                        Button("Check Now") { checkNow() }
                            .controlSize(.small)
                            .disabled(isChecking)
                    }
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

    /// About is where people go to ask "am I current?", so it answers that and nothing more —
    /// the command to actually update lives in Settings, next to the switch that controls it.
    private var updateStatus: String {
        switch app.updates.state {
        case .available(let release):
            return "\(release.version?.description ?? release.tagName) available"
        case .upToDate:
            // Never claim "up to date" off an answer from weeks ago. If the job has stopped
            // running, the truthful thing to report is that we haven't been able to look.
            return app.updates.isStale ? "Couldn't check" : "Up to date"
        case .unknown:
            return app.updates.lastFailure == nil ? "Not checked yet" : "Couldn't check"
        }
    }

    /// Runs the shipped script directly, with `--force`.
    ///
    /// Not `launchctl kickstart`: that invokes the script with no arguments, so it would hit the
    /// 20-hour throttle and do nothing, and a button that silently no-ops most of the time is
    /// worse than no button. This is the one place the app initiates a check, and only ever
    /// because someone clicked. The app still makes no network call itself — `curl` does, in a
    /// separate process, exactly as it does when launchd runs it.
    private func checkNow() {
        guard let script = Bundle.main.url(
            forResource: UpdateCheckAgent.scriptName, withExtension: nil) else { return }
        isChecking = true
        let process = Process()
        process.executableURL = script
        process.arguments = ["--force"]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                app.updates.refresh()
                isChecking = false
            }
        }
        do {
            try process.run()
        } catch {
            isChecking = false
        }
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }
}
