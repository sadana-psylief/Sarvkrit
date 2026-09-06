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
///
/// **Not main-actor, and that is deliberate.** This class used to be, and its monitor callbacks
/// reached back onto the actor with `MainActor.assumeIsolated` — an assertion, not a hop. A click
/// arriving while the main thread was blocked inside AVFoundation, which pumps the run loop as it
/// waits, reached that assertion with a main-actor frame still on the stack. The concurrency
/// runtime was asked which executor was current and answered `0x1e`; the app died in
/// `objc_opt_class`. AppKit makes no isolation promise the compiler can see, so the state is
/// lock-guarded and the callbacks record wherever they land. `RecordingWriter` reached the same
/// conclusion after the first crash in this feature: the hot path must not touch the main actor.
final class EventRecorder: @unchecked Sendable {

    private let lock = NSLock()

    private var samples: [CursorSample] = []
    private var clicks: [ClickEvent] = []
    private var keys: [KeyEvent] = []
    private var flags: [TimeInterval] = []

    private var monitors: [Any] = []
    private var isPaused = false

    /// **Absolute `systemUptime`, rebased at `finish`.**
    ///
    /// The obvious design — subtract an anchor as each sample is taken — has an ordering hole: the
    /// display link starts before the first video frame arrives, so the earliest samples would
    /// have no anchor to subtract and would be thrown away or, worse, timed from zero. Storing
    /// absolute times and rebasing once at the end removes the question.
    /// Maps a global AppKit point into the recording's own pixel space.
    private var mapPoint: (@Sendable (CGPoint) -> CGPoint?)?

    /// Whether keystrokes are being recorded. Off unless the user asked, and it needs Accessibility.
    var recordsKeystrokes: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _recordsKeystrokes }
        set { lock.lock(); _recordsKeystrokes = newValue; lock.unlock() }
    }
    private var _recordsKeystrokes = false

    /// How many global monitors are installed right now.
    ///
    /// Observable because leaking them was a real bug twice over: a start that failed part-way left
    /// them running for the life of the process, and calling `begin` again then installed a second
    /// set on top, so every click was logged twice.
    var installedMonitorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return monitors.count
    }

    func begin(mapping: @escaping @Sendable (CGPoint) -> CGPoint?) {
        // Removed first. `begin` used to install unconditionally, so a second recording after a
        // failed start ran with two monitors and doubled every click and keystroke in the log.
        removeMonitors()

        lock.lock()
        samples = []; clicks = []; keys = []; flags = []
        mapPoint = mapping
        isPaused = false
        lock.unlock()

        installMonitors()
    }

    deinit {
        // A monitor outliving its owner keeps firing into a dead closure — the same reason
        // `ShelfDragMonitor` has one of these.
        removeMonitors()
    }

    func pause() { lock.lock(); isPaused = true; lock.unlock() }
    func resume() { lock.lock(); isPaused = false; lock.unlock() }

    func flag() {
        let now = Self.currentTime()
        lock.lock(); defer { lock.unlock() }
        guard !isPaused else { return }
        flags.append(now)
    }

    /// - Parameter anchor: `systemUptime` at the instant the first video frame landed.
    ///
    /// **One clock, and this is where the two halves are joined.** Getting it wrong by 80 ms puts
    /// the pointer visibly behind what it clicked — which reads as "the app is slow" rather than
    /// as a bug, and is the single most damaging defect this feature can have.
    func finish(anchoredTo anchor: TimeInterval?) -> EventLog {
        removeMonitors()

        lock.lock(); defer { lock.unlock() }
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
        let now = Self.currentTime()
        let global = NSEvent.mouseLocation
        let kind = CursorKindReader.current()

        lock.lock(); defer { lock.unlock() }
        guard !isPaused else { return }
        let mapped = mapPoint?(global)
        samples.append(CursorSample(t: now, point: mapped ?? .zero,
                                    kind: kind, isInside: mapped != nil))
    }

    /// Absolute, not relative. See the note on the sample arrays.
    private static func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Monitors

    private func installMonitors() {
        // Global monitors observe without consuming, so nothing here can ever swallow a click or a
        // keystroke from the app being demonstrated.
        let mouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            // Recorded on whichever thread AppKit chose. No assertion, no hop — see the note on
            // the class.
            self?.record(event)
        }

        lock.lock()
        if let mouse { monitors.append(mouse) }
        let wantsKeys = _recordsKeystrokes
        lock.unlock()

        guard wantsKeys else { return }
        let keyboard = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(key: event)
        }
        lock.lock()
        if let keyboard { monitors.append(keyboard) }
        lock.unlock()
    }

    private func removeMonitors() {
        lock.lock()
        let doomed = monitors
        monitors = []
        lock.unlock()
        doomed.forEach { NSEvent.removeMonitor($0) }
    }

    private func record(_ event: NSEvent) {
        let now = Self.currentTime()
        let global = NSEvent.mouseLocation
        let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
        let button: ClickEvent.Button =
            (event.type == .rightMouseDown || event.type == .rightMouseUp) ? .right : .left

        lock.lock(); defer { lock.unlock() }
        guard !isPaused else { return }
        let mapped = mapPoint?(global)
        clicks.append(ClickEvent(t: now, point: mapped ?? .zero, button: button,
                                 isDown: isDown, isInside: mapped != nil))
    }

    private func record(key event: NSEvent) {
        lock.lock()
        let paused = isPaused
        lock.unlock()
        guard !paused else { return }

        // Never what was typed into a secure field. The check is cheap and the alternative is
        // holding somebody's password in a file on disk. Deliberately outside the lock: it is an
        // Accessibility round trip, and holding a lock across one would stall every click.
        guard !SecureFieldCheck.isFocusedElementSecure() else { return }
        guard let label = KeyLabel.describe(event) else { return }
        let now = Self.currentTime()

        lock.lock(); defer { lock.unlock() }
        keys.append(KeyEvent(t: now, label: label,
                             isModifierCombination: KeyLabel.isCombination(event)))
    }
}
