import AppKit
import CoreGraphics
import Foundation

/// Is the person at the Mac, and are they free to be interrupted?
///
/// The answers a reminder needs before it says anything. Each one is either an event (lock, sleep)
/// or a cheap poll (idle time, camera, microphone), and none needs a permission: idle time comes
/// from the HID event source, not an event tap, so it works without Accessibility.
protocol ActivitySensing: AnyObject {
    /// Seconds since the last keyboard or mouse input.
    var idleSeconds: TimeInterval { get }
    /// A camera or microphone is in use — almost always a call.
    var isInMeeting: Bool { get }
    /// Locked, asleep, or the display is off.
    var isAway: Bool { get }
    /// Called on the main queue whenever `isAway` changes.
    var onAwayChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

final class ActivitySignals: ActivitySensing {
    var onAwayChange: ((Bool) -> Void)?

    /// Three separate flags rather than one, because the events don't pair up. The display wakes
    /// to show the lock screen *before* the user unlocks it, so a single "away" bit cleared by
    /// `screensDidWake` would say the user was back while they were still typing their password —
    /// and a reminder could land on the lock screen.
    private var isLocked = false { didSet { publishIfChanged(oldAway: oldValue || isAsleep || isDisplayAsleep) } }
    private var isAsleep = false { didSet { publishIfChanged(oldAway: isLocked || oldValue || isDisplayAsleep) } }
    private var isDisplayAsleep = false { didSet { publishIfChanged(oldAway: isLocked || isAsleep || oldValue) } }

    var isAway: Bool { isLocked || isAsleep || isDisplayAsleep }

    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    var idleSeconds: TimeInterval {
        // `~0` is `kCGAnyInputEventType`, which the C header defines but the Swift enum has no case
        // for. `combinedSessionState` covers every device, including ones attached after launch.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var isInMeeting: Bool {
        CameraMonitor.isAnyCameraOn() || MicrophoneMuter.isInUse()
    }

    func start() {
        guard observers.isEmpty, distributedObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let flags: [(NSNotification.Name, ReferenceWritableKeyPath<ActivitySignals, Bool>, Bool)] = [
            (NSWorkspace.willSleepNotification, \.isAsleep, true),
            (NSWorkspace.didWakeNotification, \.isAsleep, false),
            (NSWorkspace.screensDidSleepNotification, \.isDisplayAsleep, true),
            (NSWorkspace.screensDidWakeNotification, \.isDisplayAsleep, false),
        ]
        for (name, keyPath, value) in flags {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?[keyPath: keyPath] = value
            })
        }

        // Lock has no NSWorkspace notification; it arrives as a distributed one, as in
        // `PrivacyGuardFeature`. Unlock is the half nothing else in the app needed until now.
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.isLocked = true })
        distributedObservers.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.isLocked = false })
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.forEach { workspace.removeObserver($0) }
        observers = []
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        distributedObservers = []
    }

    private func publishIfChanged(oldAway: Bool) {
        guard oldAway != isAway else { return }
        onAwayChange?(isAway)
    }

    deinit { stop() }
}
