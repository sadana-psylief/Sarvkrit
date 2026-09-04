import AppKit
import SwiftUI

/// A field that captures the next key combination pressed.
///
/// Generic over `ShortcutOwner` so the window actions and the capture actions share one recorder
/// and one conflict policy. The `WindowAction` entry point in `ShortcutConflict` is kept alongside
/// the generic one rather than replaced, because fifteen assertions pin its exact wording.
///
/// Capture goes through `NSEvent.addLocalMonitorForEvents` rather than SwiftUI's `onKeyPress`,
/// which never sees ⌘-modified keys — the same reason the clipboard picker uses a local monitor.
/// Returning nil from the monitor eats the event, so the combination being recorded doesn't also
/// act on whatever is behind the settings window.
struct ShortcutRecorderView<Owner: ShortcutOwner>: View {
    let action: Owner
    let current: WindowShortcut?
    /// Existing bindings, so the recorder can say what a combination would displace.
    let existing: [Owner: WindowShortcut]
    let onRecord: (WindowShortcut?) -> Void
    /// Suspends the event tap while capturing, so a bound combination doesn't move a window as
    /// it is typed.
    let onRecordingChanged: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var refusal: String?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(action: toggle) {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .frame(minWidth: 74)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 3)
                    .background(background, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            isRecording ? Color.accentColor : .clear,
                            lineWidth: 1
                        )
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .clickableCursor()
            .help(isRecording ? "Press a combination, or ⎋ to cancel" : "Click to change")

            if let refusal {
                Text(refusal)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 210, alignment: .trailing)
            }
        }
        // A monitor that outlives its view eats keystrokes for the rest of the session.
        .onDisappear(perform: stop)
        // …and one that outlives the *window losing focus* does the same without the view ever
        // disappearing. Click a pill, click elsewhere without pressing a key, and every keyDown
        // in the app was being swallowed — typing went dead everywhere, including in this pane's
        // own text fields.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stop()
        }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        if let current { return current.displayString }
        return isHovering ? "Set…" : "—"
    }

    private var foreground: Color {
        if isRecording { return .accentColor }
        return current == nil ? .secondary : .primary
    }

    private var background: some ShapeStyle {
        isRecording ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                    : AnyShapeStyle(.quaternary.opacity(isHovering ? 0.9 : 0.5))
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard monitor == nil else { return }
        refusal = nil
        isRecording = true
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil   // never let the recorded combination reach the window behind
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged(false)
    }

    private func capture(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)

        // Escape cancels and Delete clears, both before any policy runs — otherwise ⌃⌥⌫, the
        // default for Restore, could never be re-recorded.
        if keyCode == WindowShortcut.escapeKey, event.modifierFlags.sarvkritEventFlags.isEmpty {
            stop()
            return
        }
        if keyCode == WindowShortcut.deleteKey, event.modifierFlags.sarvkritEventFlags.isEmpty {
            onRecord(nil)
            stop()
            return
        }

        let shortcut = WindowShortcut(
            keyCode: keyCode,
            modifiers: event.modifierFlags.sarvkritEventFlags
        )
        let verdict = ShortcutConflict.verdict(for: shortcut, existing: existing,
                                               assigningTo: action)

        guard verdict.isAllowed else {
            // Stay open so the user can simply try another combination.
            refusal = verdict.message
            return
        }
        refusal = verdict.message   // nil when clean; a warning when it displaces something
        onRecord(shortcut)
        stop()
    }
}

extension NSEvent.ModifierFlags {
    /// The four modifiers a binding may use, as `CGEventFlags`. `NSEvent` reports a superset that
    /// includes caps lock and the numeric-keypad bit, neither of which a shortcut should carry.
    var sarvkritEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
