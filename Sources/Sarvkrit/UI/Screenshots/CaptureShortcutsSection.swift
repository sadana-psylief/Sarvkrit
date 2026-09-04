import SwiftUI

/// The rebindable capture shortcuts.
struct CaptureShortcutsSection: View {
    @ObservedObject var feature: ScreenshotFeature
    @ObservedObject var shortcuts: ScreenshotShortcutStore
    @EnvironmentObject private var app: AppState

    /// Pin's shortcut belongs to the other feature, which registers it itself.
    private var actions: [ScreenshotAction] {
        ScreenshotAction.allCases.filter { $0 != .pinClipboard }
    }

    var body: some View {
        Section {
            ForEach(actions) { action in
                LabeledContent(action.title) {
                    HStack(spacing: Theme.Space.sm) {
                        if feature.failedRegistrations.contains(action) {
                            // Said plainly rather than left as a shortcut that appears bound and
                            // does nothing — which is the actual failure when another app or the
                            // system already owns the combination.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Another app already has this combination")
                                .accessibilityLabel("Not registered")
                        }
                        ShortcutRecorderView(
                            action: action,
                            current: shortcuts.shortcut(for: action),
                            existing: shortcuts.bindings,
                            onRecord: { shortcut in
                                shortcuts.bind(action, to: shortcut)
                                feature.rebindHotkeys()
                            },
                            onRecordingChanged: { _ in })
                    }
                }
            }
            Button("Reset to Defaults") {
                shortcuts.resetToDefaults()
                feature.rebindHotkeys()
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("""
                ⌘⇧3, ⌘⇧4 and ⌘⇧5 belong to the macOS screenshot service, which claims them before \
                Sarvkrit can. You can still record one — it just won't fire, and it will be marked \
                here — so turn them off in System Settings › Keyboard › Keyboard Shortcuts › \
                Screenshots first if you want them.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
