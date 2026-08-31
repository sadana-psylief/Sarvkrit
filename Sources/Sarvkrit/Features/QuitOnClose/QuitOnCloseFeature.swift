import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Makes the red ✕ quit an app once its last window is gone, so ⌘Q becomes optional.
///
/// The click is never swallowed — it has to reach the close button and close the window
/// normally. We only watch, and then follow up.
///
/// Timing note: the hit-test runs on **mouse down**, while the button is still on screen and
/// answering AX queries. Waiting until mouse up would race the window's disappearance. All AX
/// work happens on a serial background queue, never in the tap callback, which keeps a slow
/// app from tripping the tap's watchdog.
final class QuitOnCloseFeature: EventTapFeature {
    let id = "quit-on-close"
    let category = FeatureCategory.windows
    let title = "Quit on Close"
    let summary = "Red ✕ fully quits the app"
    let details = """
        Closing an app's last window with the red ✕ quits the app, instead of leaving it \
        running with nothing on screen.

        Sarvkrit asks the app to quit the same way ⌘Q does, so unsaved work still prompts you \
        to save. Apps that keep other windows open are left alone, and Finder is always \
        excluded — quitting it would take the desktop with it.
        """
    let symbolName = "xmark.circle"

    var eventMask: CGEventMask { Sarvkrit.eventMask(.leftMouseDown, .leftMouseUp) }

    /// How long to let the window actually go away before counting what's left.
    private let settleDelay: TimeInterval = 0.45
    /// A press that travels further than this is a drag (moving the window by its titlebar),
    /// not a click on the close button.
    private let maxClickDrift: CGFloat = 6

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "QuitOnClose")
    /// All mutable state below is touched only on this queue. Serial ordering is what
    /// guarantees the mouse-down hit test is finished before the matching mouse-up is read.
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).quit-on-close")
    private var armedPID: pid_t?
    private var armedPoint: CGPoint?

    func deactivate() {
        queue.async {
            self.armedPID = nil
            self.armedPoint = nil
        }
    }

    func handle(event: CGEvent, type: CGEventType) -> EventDecision {
        let location = event.location
        switch type {
        case .leftMouseDown:
            queue.async { self.armIfCloseButton(at: location) }
        case .leftMouseUp:
            queue.async { self.releaseAndScheduleCheck(at: location) }
        default:
            break
        }
        // Never consume the click: the close button still has to do its job.
        return .pass
    }

    private func armIfCloseButton(at point: CGPoint) {
        armedPID = nil
        armedPoint = nil

        guard let element = AX.element(at: point),
              let pid = AX.pid(of: element),
              // Our own windows, decided *before* the role and subrole reads below.
              //
              // An Accessibility query is answered by the target process's own main run loop, so
              // asking about our own window means asking our own main thread — the one already busy
              // rendering whatever was just clicked. This ran on every left click anywhere on the
              // system, our own settings window included.
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier != Self.ownBundleID
        else { return }

        let target = CloseButtonHitTest.Target(
            role: AX.string(element, kAXRoleAttribute as String),
            subrole: AX.string(element, kAXSubroleAttribute as String),
            bundleID: app.bundleIdentifier,
            isRegularApp: app.activationPolicy == .regular
        )
        guard CloseButtonHitTest.isCloseButton(target, ownBundleID: Self.ownBundleID) else { return }

        armedPID = pid
        armedPoint = point
    }

    private func releaseAndScheduleCheck(at point: CGPoint) {
        guard let pid = armedPID, let down = armedPoint else { return }
        armedPID = nil
        armedPoint = nil

        let drift = hypot(point.x - down.x, point.y - down.y)
        guard drift <= maxClickDrift else { return }

        queue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.terminateIfNoWindowsLeft(pid: pid)
        }
    }

    private func terminateIfNoWindowsLeft(pid: pid_t) {
        // nil means the app couldn't be asked — it already quit, or it's busy. Either way
        // that is not "zero windows", and acting on it would kill apps for being slow.
        let count = AX.windowCount(pid: pid)
        guard CloseButtonHitTest.shouldTerminate(windowCount: count),
              let app = NSRunningApplication(processIdentifier: pid)
        else { return }

        log.info("last window closed for \(app.bundleIdentifier ?? "unknown") — requesting quit")
        DispatchQueue.main.async {
            // terminate(), not forceTerminate(): the app gets to prompt about unsaved work.
            app.terminate()
        }
    }

    private static let ownBundleID = AppIdentity.bundleID
}
