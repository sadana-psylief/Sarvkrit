import CoreGraphics

/// Where the menu bar dropdown belongs when its content changes height.
///
/// A `MenuBarExtra` window is positioned by the system once, at presentation, and is not
/// re-anchored when its content changes size — so switching to a shorter tab drags the panel away
/// from the menu bar. Correcting that means recomputing an origin, and an origin computed against
/// a live display is a thing you can only check by eye on the display you happen to own. Pure, for
/// the same reason `ScreenPlacement` is: the multi-display and short-screen cases are the ones most
/// likely to be wrong and least likely to be noticed.
enum MenuBarPanelPlacement {

    /// How far from the menu bar's bottom edge a window's top may sit and still be believed to be
    /// the system's own placement.
    ///
    /// Only there to reject a frame that was never positioned at all; it can afford to be generous
    /// because a top edge is only ever captured at presentation, never after a resize. Measured on
    /// a 15" display the system leaves a **2pt** gap below `visibleFrame.maxY`, and with
    /// "Automatically hide and show the menu bar" on, `visibleFrame` stops describing the menu bar
    /// and the same placement reads ~33pt down — so anything tighter than that would reject a
    /// perfectly good anchor in a setting nobody thinks to test.
    static let anchorTolerance: CGFloat = 48

    /// Sub-pixel differences are not worth moving a window for, as
    /// `ClipboardPickerController.resize(to:)` also decided.
    static let moveTolerance: CGFloat = 0.5

    /// Whether `top` is close enough to `menuBarBottom` to be the system's placement.
    ///
    /// `menuBarBottom` is a parameter rather than derived here, and not only for purity: the
    /// obvious candidates disagree. `NSScreen.visibleFrame.maxY` matched the system's own placement
    /// to 2pt when measured, while `NSStatusBar.system.thickness` reported 22pt against a menu bar
    /// actually 33pt tall — 11pt of error, and a panel visibly hanging off the bar. The caller
    /// says which one it means.
    static func isPlausibleAnchor(
        top: CGFloat,
        menuBarBottom: CGFloat,
        tolerance: CGFloat = anchorTolerance
    ) -> Bool {
        abs(menuBarBottom - top) <= tolerance
    }

    /// The frame origin — AppKit's bottom-left — for a panel of `height` whose top edge belongs
    /// at `top`.
    ///
    /// `x` is passed through and only clamped: the horizontal position is the system's, it is
    /// already correct (it does not move when the panel resizes), and deriving it would mean
    /// guessing at the status item's position — the one number that would unmoor the panel
    /// sideways if guessed wrong.
    static func origin(
        forHeight height: CGFloat,
        x: CGFloat,
        top: CGFloat,
        width: CGFloat,
        in visible: CGRect
    ) -> CGPoint {
        var left = x
        if left + width > visible.maxX { left = visible.maxX - width }
        if left < visible.minX { left = visible.minX }

        // Never up under the menu bar, whatever it was asked for.
        let clampedTop = min(top, visible.maxY)

        // The top is the anchored edge, and there is deliberately no lower clamp: a panel too tall
        // for the space beneath the menu bar overflows the bottom rather than being pushed up. The
        // alternative is worse in exactly the way this whole file exists to prevent — lifting it to
        // fit would slide it off the icon it belongs to, and far enough would tuck its header under
        // the menu bar. Content that tall is a content problem, answered by scrolling.
        return CGPoint(x: left, y: clampedTop - height)
    }

    static func needsMove(
        from current: CGPoint,
        to desired: CGPoint,
        tolerance: CGFloat = moveTolerance
    ) -> Bool {
        abs(current.x - desired.x) > tolerance || abs(current.y - desired.y) > tolerance
    }
}
