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
    private var subscribers: [EventTapFeature] = []

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
        subscribers = features
        let mask = features.reduce(CGEventMask(0)) { $0 | $1.eventMask }
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

    /// Marks an event as ours before posting it.
    static func tagAsSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own synthesized events pass straight through, untouched and unseen by any feature.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.warning("tap disabled by system (\(type.rawValue)) — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        for subscriber in subscribers {
            guard subscriber.eventMask & (1 << CGEventMask(type.rawValue)) != 0 else { continue }
            if case .swallow = subscriber.handle(event: event, type: type) {
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
