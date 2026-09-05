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

    /// **Absolute `systemUptime`, rebased at `finish`.**
    ///
    /// The obvious design — subtract an anchor as each sample is taken — has an ordering hole: the
    /// display link starts before the first video frame arrives, so the earliest samples would
    /// have no anchor to subtract and would be thrown away or, worse, timed from zero. Storing
    /// absolute times and rebasing once at the end removes the question.
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

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func flag() {
        guard let now = currentTime() else { return }
        flags.append(now)
    }

    /// - Parameter anchor: `systemUptime` at the instant the first video frame landed.
    ///
    /// **One clock, and this is where the two halves are joined.** Getting it wrong by 80 ms puts
    /// the pointer visibly behind what it clicked — which reads as "the app is slow" rather than
    /// as a bug, and is the single most damaging defect this feature can have.
    func finish(anchoredTo anchor: TimeInterval?) -> EventLog {
        removeMonitors()
        guard let anchor else { return EventLog() }

        // Anything from before the first frame belongs to no picture, so it is dropped rather than
        // given a negative time.
        let rebased = samples.filter { $0.t >= anchor }.map { sample -> CursorSample in
            var moved = sample
            moved.t -= anchor
            return moved
        }
        let movedClicks = clicks.filter { $0.t >= anchor }.map { click -> ClickEvent in
            var moved = click
            moved.t -= anchor
            return moved
        }
        let movedKeys = keys.filter { $0.t >= anchor }.map { key -> KeyEvent in
            var moved = key
            moved.t -= anchor
            return moved
        }
        return EventLog(cursor: rebased, clicks: movedClicks, keys: movedKeys,
                        flags: flags.filter { $0 >= anchor }.map { $0 - anchor })
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

    /// Absolute, not relative. See the note on the sample arrays.
    private func currentTime() -> TimeInterval? {
        ProcessInfo.processInfo.systemUptime
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
