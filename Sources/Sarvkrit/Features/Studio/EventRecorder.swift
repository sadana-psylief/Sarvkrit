import AppKit
import Foundation

/// Captures what the mouse and keyboard did, alongside the video.
///
/// **This is the half that makes the feature what it is.** The screen is recorded with
/// `showsCursor = false`, so without this log there is no cursor at all; with it, the pointer can
/// be redrawn at any size, smoothed, given motion blur, and kept sharp at 2.5× zoom — and the
/// zooms themselves can be invented afterwards from where the clicks landed.
///
/// **Clicks need no permission.** `NSEvent.addGlobalMonitorForEvents` for mouse events is
/// unprivileged, so the base recorder never touches the shared event tap and recording your screen
/// asks for exactly one grant: the one macOS makes unavoidable.
@MainActor
final class EventRecorder {

    private var samples: [CursorSample] = []
    private var clicks: [ClickEvent] = []
    private var keys: [KeyEvent] = []
    private var flags: [TimeInterval] = []

    private var monitors: [Any] = []
    private var displayLink: CADisplayLink?
    private var isPaused = false

    /// Set once the first video frame lands, so events and frames share one clock.
    private var startedAt: TimeInterval?
    /// Maps a global AppKit point into the recording's own pixel space.
    private var mapPoint: ((CGPoint) -> CGPoint?)?

    /// Whether keystrokes are being recorded. Off unless the user asked, and it needs Accessibility.
    var recordsKeystrokes = false

    func begin(mapping: @escaping (CGPoint) -> CGPoint?) {
        samples = []; clicks = []; keys = []; flags = []
        mapPoint = mapping
        isPaused = false
        installMonitors()
    }

    /// Called with the presentation timestamp of the first video frame.
    ///
    /// **One clock, and this is where it is set.** Everything else is measured from here, so the
    /// cursor cannot drift against the picture. Getting this wrong by 80 ms puts the pointer
    /// visibly behind what it clicked, which reads as "the app is slow" rather than as a bug.
    func anchor(to hostTime: TimeInterval) {
        startedAt = hostTime
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func flag() {
        guard let now = currentTime() else { return }
        flags.append(now)
    }

    func finish() -> EventLog {
        removeMonitors()
        return EventLog(cursor: samples, clicks: clicks, keys: keys, flags: flags)
    }

    // MARK: - Sampling

    /// Sampled at the display's refresh rate rather than taken from move events, because move
    /// events stop arriving the moment the mouse stops — and a path with no samples during a pause
    /// cannot be interpolated across it.
    func sampleCursor() {
        guard !isPaused, let now = currentTime() else { return }
        let global = NSEvent.mouseLocation
        let mapped = mapPoint?(global)
        samples.append(CursorSample(t: now,
                                    point: mapped ?? .zero,
                                    kind: CursorKindReader.current(),
                                    isInside: mapped != nil))
    }

    private func currentTime() -> TimeInterval? {
        guard let startedAt else { return nil }
        return ProcessInfo.processInfo.systemUptime - startedAt
    }

    // MARK: - Monitors

    private func installMonitors() {
        // Global monitors observe without consuming, so nothing here can ever swallow a click or a
        // keystroke from the app being demonstrated.
        let mouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }
        if let mouse { monitors.append(mouse) }

        guard recordsKeystrokes else { return }
        let keyboard = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(key: event) }
        }
        if let keyboard { monitors.append(keyboard) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func record(_ event: NSEvent) {
        guard !isPaused, let now = currentTime() else { return }
        let global = NSEvent.mouseLocation
        let mapped = mapPoint?(global)
        let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
        let button: ClickEvent.Button =
            (event.type == .rightMouseDown || event.type == .rightMouseUp) ? .right : .left
        clicks.append(ClickEvent(t: now, point: mapped ?? .zero, button: button,
                                 isDown: isDown, isInside: mapped != nil))
    }

    private func record(key event: NSEvent) {
        guard !isPaused, let now = currentTime() else { return }
        // Never what was typed into a secure field. The check is cheap and the alternative is
        // holding somebody's password in a file on disk.
        guard !SecureFieldCheck.isFocusedElementSecure() else { return }
        guard let label = KeyLabel.describe(event) else { return }
        keys.append(KeyEvent(t: now, label: label,
                             isModifierCombination: KeyLabel.isCombination(event)))
    }
}
