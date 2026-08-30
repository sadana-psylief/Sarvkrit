import SwiftUI

/// Three beats: what Sarvkrit does, why it needs Accessibility, grant it.
///
/// The permission poll flips the row to a checkmark live, so the user never has to come back
/// and click something to confirm. That instant flip is what makes the step feel handled
/// rather than abandoned.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    var onFinish: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Welcome to Sarvkrit")
                        .font(.title2.weight(.semibold))
                    Text("Small fixes for the things macOS does differently than you'd expect. Turn each one on or off whenever you like.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.Space.sm)
            }

            Section("Why Accessibility access") {
                Text("""
                    Sarvkrit watches for the specific keys and clicks you've switched on, and \
                    nothing else. It doesn't record what you type, and it never sends anything \
                    off your Mac. macOS calls this Accessibility access because it's the same \
                    permission apps use to control the interface on your behalf.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Accessibility access") {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: app.permissions.isTrusted
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(app.permissions.isTrusted ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(app.permissions.isTrusted ? "Granted" : "Waiting…")
                            .foregroundStyle(.secondary)
                    }
                }

                if app.permissions.isTrusted {
                    Button("Continue") {
                        app.hasCompletedOnboarding = true
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    HStack(spacing: Theme.Space.md) {
                        Button("Grant Access…") { app.permissions.requestAccess() }
                            .keyboardShortcut(.defaultAction)
                        // macOS only shows its own prompt once per install, so the direct
                        // link is the reliable path on every run after the first.
                        Button("Open System Settings") { app.permissions.openSystemSettings() }
                    }
                }
            } footer: {
                if !app.permissions.isTrusted {
                    Text("In System Settings, turn on Sarvkrit under Privacy & Security → Accessibility. This screen updates on its own once you do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Set Up Sarvkrit")
    }
}
