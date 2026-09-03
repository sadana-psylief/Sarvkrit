import AppKit
import CoreGraphics

/// Hides the pointer while a capture overlay is up, from a background app.
///
/// **Both of these are scoped to the active application**, which is the thing to know about them.
/// Sarvkrit is an accessory app and the overlay usually opens while something else is frontmost —
/// exactly the hotkey path — and there neither call does anything: the arrow stays sitting on top
/// of the crosshair. I checked, by photographing the pointer through ScreenCaptureKit with
/// `showsCursor` while the overlay was up from a background delivery, which is the only way to
/// observe it from outside the process.
///
/// So the mechanism that actually hides the pointer is `SelectionView`'s cursor rect, which the
/// window server honours for whichever window is under the pointer regardless of who is active.
/// This stays as the belt to that pair of braces — it covers the case where the app *is* frontmost
/// and the pointer is over a different display than the panel — and because it is balanced and
/// tested, keeping it costs nothing.
///
/// **Balanced, always.** The hide is reference-counted, and a cursor that is never shown again is
/// a Mac the user cannot operate — the worst failure this feature could have. So: one flag, a
/// single owner, `show()` is idempotent, and `CaptureOverlayGuard` calls it too. The final
/// backstop is the kernel's, which restores the cursor when the process exits.
@MainActor
enum OverlayCursor {
    private(set) static var isHidden = false

    static func hide() {
        guard !isHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        // Both, because they count separately and the AppKit one is what a foreground
        // `NSCursor.unhide()` elsewhere in the app would otherwise unbalance.
        NSCursor.hide()
        isHidden = true
    }

    static func show() {
        guard isHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
        isHidden = false
    }
}
