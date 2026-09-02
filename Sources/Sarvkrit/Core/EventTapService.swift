import CoreGraphics
import Foundation
import os

/// The single `CGEventTap` every feature shares.
///
/// Three things here are load-bearing and easy to get wrong:
///
/// 1. `.defaultTap` (not `.listenOnly`) — we rewrite events, which is also precisely what
///    makes macOS demand the **Accessibility** grant rather than mere Input Monitoring.
/// 2. The tap is created lazily and torn down when the last feature is switched off, so an
///    all-off Sarvkrit adds exactly zero overhead per keystroke.
/// 3. `.tapDisabledByTimeout` must be handled. macOS disables a tap whose callback ever runs
///    long, and it does **not** tell you — without the re-enable below, every feature works
///    for a while and then silently dies until relaunch.
final class EventTapService {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "EventTap")

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Subscribers paired with their mask, **sampled once** when the tap is built.
    ///
    /// `eventMask` is a computed property on every feature, and one of them reads `UserDefaults`
    /// to decide whether it wants mouse events. Reading it per subscriber per event meant a
    /// defaults lookup on every keystroke and every drag on the system — and since this callback
    /// runs on the main run loop, that cost is paid by whatever app the user is actually typing
    /// in. A mask can only change through a resync, which rebuilds the tap and re-samples here.
    private var subscribers: [(feature: EventTapFeature, mask: CGEventMask)] = []

    var isRunning: Bool { tap != nil }

    /// The C callback holds `self` **unretained** — it must, or the service would never
    /// deallocate. That makes stopping on deallocation mandatory rather than tidy: a tap left
    /// installed after its owner is gone dereferences freed memory on the next event and crashes
    /// the process. `AppState.shared` lives forever so the app never hit this, but anything else
    /// creating a service would.
    deinit {
        stop()
    }

    /// Rebuilds the tap around exactly these features. Passing an empty array tears it down.
    /// Returns false if the tap could not be created — almost always missing Accessibility.
    @discardableResult
    func setSubscribers(_ features: [EventTapFeature]) -> Bool {
        stop()
        guard !features.isEmpty else { return true }
        subscribers = features.map { ($0, $0.eventMask) }
        let mask = subscribers.reduce(CGEventMask(0)) { $0 | $1.mask }
        return start(mask: mask)
    }

    private func start(mask: CGEventMask) -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("tapCreate failed — Accessibility permission is almost certainly missing")
            subscribers = []
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        log.info("event tap started with \(self.subscribers.count) subscriber(s)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        subscribers = []
    }

    /// Runs on the main run loop, in the path of every matching event. Keep it cheap: no AX
    /// calls, no allocation-heavy work, nothing blocking. Features that need any of that
    /// hop off-thread themselves.
    /// Stamped into `.eventSourceUserData` on every event Sarvkrit posts itself.
    ///
    /// Without this, a synthesized ⌘V re-enters this tap and `CutPasteFeature` rewrites it into a
    /// Finder *move* — pasting from the clipboard history would relocate files. Guarding centrally
    /// means a new feature that posts events can't forget.
    static let syntheticEventTag: Int64 = 0x5341_5256   // "SARV"

    /// Diagnostics for a stray capital X that inspection could not explain.
    ///
    /// **Scope is deliberately one character.** A tap sees every keystroke on the Mac, so a
    /// diagnostic here is one careless line away from being a keylogger — which would undo the
    /// entire premise of how Snippets is built. Nothing below records *which* keys were pressed:
    /// only the X case in full, and elsewhere a bare count.
    ///
    /// Matching is on the **character**, not just the keycode. `SnippetTyper.type()` posts
    /// `virtualKey: 0` with the text in the unicode string, so a keycode filter alone would let an
    /// X this app typed pass unlogged — the exact case the log is supposed to settle.
    private static func noteIfX(_ event: CGEvent, type: CGEventType, ours: Bool) {
        guard type == .keyDown || type == .keyUp else { return }

        if type == .keyDown { recentKeyDowns.record() }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 7 || carriesX(event) else { return }

        // The field that actually answers the question. Every CGEvent records the PID of whatever
        // posted it: 0 for real hardware coming up through the HID stack, otherwise the injecting
        // process. Three rounds of reading code could not distinguish "we typed it", "another app
        // typed it" and "the keyboard did it"; this integer does.
        let postedBy = event.getIntegerValueField(.eventSourceUnixProcessID)
        // A second, independent read on the same question: physical keyboards report a nonzero
        // type, synthesized events almost always report 0.
        let keyboardType = event.getIntegerValueField(.keyboardEventKeyboardType)

        diagnosticLog.notice(
            """
            X key \(type == .keyDown ? "down" : "up", privacy: .public)             — posted by PID \(postedBy, privacy: .public),             tagged as ours: \(ours, privacy: .public),             keycode \(keyCode, privacy: .public),             keyboardType \(keyboardType, privacy: .public),             flags \(event.flags.rawValue, privacy: .public),             keyDowns in the last 10s: \(recentKeyDowns.count(), privacy: .public)
            """
        )
    }

    /// Whether the event would insert an "X", whatever keycode it claims to be.
    private static func carriesX(_ event: CGEvent) -> Bool {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length == 1 else { return false }
        return buffer[0] == 0x58   // "X"
    }

    /// How many keys were pressed recently — **a count, never which keys.**
    ///
    /// This is the one thing the previous diagnostic could not tell us: an X arriving in total
    /// isolation while the user sits still is a bug, whereas the same X arriving mid-sentence is a
    /// typo. Distinguishing them needs no knowledge of what was typed, so none is kept.
    private struct KeyDownCounter {
        private static let window: TimeInterval = 10
        private var timestamps: [TimeInterval] = []

        mutating func record() {
            let now = Date.timeIntervalSinceReferenceDate
            timestamps.removeAll { now - $0 > Self.window }
            timestamps.append(now)
        }

        func count() -> Int {
            let now = Date.timeIntervalSinceReferenceDate
            return timestamps.filter { now - $0 <= Self.window }.count
        }
    }

    /// Only ever touched from the tap callback, which runs on the main run loop.
    private static var recentKeyDowns = KeyDownCounter()

    private static let diagnosticLog = Logger(
        subsystem: AppIdentity.logSubsystem, category: "StrayKeyDiagnostic")

    /// Marks an event as ours before posting it.
    static func tagAsSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own synthesized events pass straight through, untouched and unseen by any feature.
        let isOurs = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag
        if isOurs {
            Self.noteIfX(event, type: type, ours: true)
            return Unmanaged.passUnretained(event)
        }
        Self.noteIfX(event, type: type, ours: false)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Logged where the X diagnostic can see it: a stalled tap delays real input, which
            // is indistinguishable from a phantom keystroke to anyone watching the screen.
            Self.diagnosticLog.notice(
                "tap disabled by system (\(type.rawValue, privacy: .public)) — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let bit = CGEventMask(1) << CGEventMask(type.rawValue)
        for (subscriber, mask) in subscribers {
            guard mask & bit != 0 else { continue }
            if case .swallow = subscriber.handle(event: event, type: type) {
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
