import AppKit
import Carbon.HIToolbox
import os

/// The way out of anything this feature puts on screen.
///
/// **Every window in the capture category floats above normal content, and one of them
/// deliberately ignores clicks.** That combination can strand a user: a pinned shot in Lock Mode
/// takes no clicks by design, a capture overlay sits above the menu bar at shielding level, and if
/// any of them is left behind there is nothing to click on to get rid of it. That is not a
/// theoretical worry — it is the single worst thing this feature can do to someone, because the
/// screen is the thing they need in order to fix it.
///
/// So there is one shortcut that always works and always means "get everything off my screen".
/// It is registered with Carbon, which needs no permission, so it keeps working even when
/// Accessibility has been revoked; it is registered whenever *either* capture feature is on, not
/// only while something is showing, so it cannot be missing at the moment it is needed; and it
/// tears down everything unconditionally rather than asking any controller whether it thinks it
/// has anything up.
@MainActor
final class CaptureOverlayGuard {
    static let shared = CaptureOverlayGuard()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")
    private var hotkey: GlobalHotkey?
    private var localMonitor: Any?

    /// ⌃⇧⎋ — deliberately not a letter. It has to be something nothing else plausibly claims and
    /// that a stuck user can be told over the phone.
    static let shortcutDescription = "⌃⇧⎋"

    func install() {
        guard hotkey == nil else { return }
        let hotkey = GlobalHotkey(id: GlobalHotkey.ID.dismissAllOverlays)
        let status = hotkey.register(keyCode: UInt32(kVK_Escape),
                                     modifiers: UInt32(controlKey | shiftKey)) {
            MainActor.assumeIsolated { CaptureOverlayGuard.shared.dismissEverything() }
        }
        if status != noErr {
            log.error("couldn't register the overlay escape hatch: \(status, privacy: .public)")
        }
        self.hotkey = hotkey

        // A plain Escape also works while one of our own windows has focus, which covers the
        // common case without the user having to remember the combination at all.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated {
                guard CaptureOverlayGuard.shared.isAnythingShowing else { return }
                CaptureOverlayGuard.shared.dismissEverything()
            }
            return event
        }
    }

    func uninstall() {
        hotkey?.unregister()
        hotkey = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    var isAnythingShowing: Bool {
        CaptureOverlayController.shared.isPresenting
            || AllInOneController.shared.isPresenting
            || ScrollCaptureSession.shared.isRunning
            || PinnedShotController.shared.count > 0
            || CaptureHistoryWindowController.shared.isPresenting
    }

    /// Takes everything down. Safe to call at any time, including when nothing is up.
    ///
    /// Unlocks before closing so a pin that ignores mouse events cannot survive as an invisible
    /// click-blocker if closing it somehow fails.
    func dismissEverything() {
        PinnedShotController.shared.unlockAll()
        PinnedShotController.shared.closeAll()
        CaptureOverlayController.shared.dismiss()
        AllInOneController.shared.dismiss()
        CountdownPresenter.shared.cancel()
        ScrollCaptureSession.shared.cancel()
        QuickAccessController.shared.closeAll()
        CaptureHistoryWindowController.shared.dismiss()
        NSCursor.unhide()
    }
}
