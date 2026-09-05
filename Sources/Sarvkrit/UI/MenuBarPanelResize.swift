import CoreGraphics

/// When the tray panel's resize is worth animating, and which two frames it runs between.
///
/// Split out from `MenuBarWindowAnchor` for the same reason `MenuBarPanelPlacement` was: the
/// interesting cases are the ones a single-display machine with the panel open cannot be made to
/// perform on demand. A resize arriving while another is still running, the first placement of a
/// presentation, Reduce Motion, a content height that changes on its own every couple of seconds
/// — each is one function call here and an afternoon of clicking otherwise.
///
/// `MenuBarPanelPlacement` answers *where* a panel of a given height goes. This answers *how it
/// gets there*, and defers every question about position to that file.
///
/// A resize is animated when the content grew, and snapped otherwise — a shrink, Reduce
/// Motion, the first placement of a presentation, and drift correction. That distinction is the
/// whole point: animation is how this panel says "the content changed", and spending it on a
/// stale origin would be motion that explains nothing.
enum MenuBarPanelResize {

    /// What the anchor should do about the height it was just told about.
    enum Step: Equatable {
        /// Nothing worth moving a window for.
        case none
        /// Go there now: Reduce Motion, the first placement of a presentation, or a correction
        /// that isn't a content change and so isn't a resize the user should watch happen.
        case set(CGRect)
        /// Put the window at `from` — undoing SwiftUI's jump to the settled height — and animate
        /// it to `to`.
        ///
        /// Both frames come from `MenuBarPanelPlacement.origin(...)` against the same anchor, so
        /// `from.maxY == to.maxY` by construction. That is what keeps the top edge still while the
        /// height changes: interpolating the whole rect moves the origin by `Δy = −Δh`, so
        /// `y(t) + h(t)` is constant for every `t`. Animating height and origin as two properties
        /// would not have that guarantee, and the top edge would wobble by rounding.
        case animate(from: CGRect, to: CGRect)
    }

    /// The frame a panel of `height` should occupy, top edge on `top`.
    static func frame(
        forHeight height: CGFloat,
        x: CGFloat,
        top: CGFloat,
        width: CGFloat,
        in visible: CGRect
    ) -> CGRect {
        CGRect(
            origin: MenuBarPanelPlacement.origin(
                forHeight: height, x: x, top: top, width: width, in: visible),
            size: CGSize(width: width, height: height)
        )
    }

    /// - Parameters:
    ///   - window: the frame the window has right now — which on a grow is already the settled
    ///     height, because SwiftUI put it there before the content report arrived.
    ///   - settledHeight: the height the last completed step left behind. `0` means this
    ///     presentation has not placed the panel yet.
    ///   - contentHeight: the probe's latest measurement of the content.
    ///   - inFlightTo: the destination of an animation that is still running, if any.
    static func step(
        window: CGRect,
        settledHeight: CGFloat,
        contentHeight: CGFloat,
        inFlightTo: CGRect?,
        anchorTop: CGFloat,
        visible: CGRect,
        animates: Bool,
        tolerance: CGFloat = MenuBarPanelPlacement.moveTolerance
    ) -> Step {
        // Nothing has been laid out yet. Sizing a window to zero is worse than leaving it alone.
        guard contentHeight > 0 else { return .none }

        let target = frame(
            forHeight: contentHeight,
            x: window.minX,
            top: anchorTop,
            width: window.width,
            in: visible
        )

        // Reduce Motion is checked before anything else, including an animation already running:
        // "never animate" has to mean never, and a setting switched on mid-flight should land the
        // panel rather than finish the movement it asked not to see.
        guard animates else {
            return same(window, target, tolerance: tolerance) ? .none : .set(target)
        }

        // A resize arriving mid-animation. Two of these are common: a fast double tab switch, and
        // the Volume Mixer's list of playing apps changing height on its own inside the 150ms.
        if let inFlightTo {
            // Already on its way to this height — a repeat report, not a new destination.
            if abs(inFlightTo.height - contentHeight) <= tolerance { return .none }
            // A genuinely new destination. Start from wherever the window has got to, not from
            // the height this animation began at, or the panel jumps backwards before setting off.
            return .animate(from: window, to: target)
        }

        // The first placement of a presentation. The panel must appear at its size: the system has
        // its own opening animation, and growing into place on top of that reads as a stutter.
        guard settledHeight > tolerance else {
            return same(window, target, tolerance: tolerance) ? .none : .set(target)
        }

        // The content did not change height, so any difference is drift — a stale origin, a
        // rounding residue, a display change. Correct it, but do not perform it: animation is how
        // this panel says "the content changed", and spending it on a 1pt correction is noise.
        if abs(settledHeight - contentHeight) <= tolerance {
            return same(window, target, tolerance: tolerance) ? .none : .set(target)
        }

        // A **shrink** snaps. Measured, and it is a difference in what there is to look at
        // rather than in the frames: an animated grow reveals the new content as the window opens
        // over it, and an animated shrink has nothing to reveal — the content is already short and
        // pinned to the top, so all that moves is the bottom edge travelling up through empty
        // panel material. Instrumented, shrinks also came off worse than grows on their own terms:
        // one lost 64% of its travel in a single step and ran in 118ms rather than 250, another
        // stalled 50ms mid-run, where every grow stayed inside 15% and 17ms.
        //
        // Snapping it is not a consolation prize. The window and the content agree on height
        // immediately, which is the state this whole file exists to produce.
        guard contentHeight > settledHeight else {
            return same(window, target, tolerance: tolerance) ? .none : .set(target)
        }

        // A grow: the direction with something to show. The window opens downward over content
        // that `TopPinnedContentView` is already holding at full height against the top edge, so
        // the new panel is revealed rather than stretched.
        let from = frame(
            forHeight: settledHeight,
            x: window.minX,
            top: anchorTop,
            width: window.width,
            in: visible
        )
        return .animate(from: from, to: target)
    }

    /// Whether two frames are the same to within the tolerance a window move is worth.
    static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = MenuBarPanelPlacement.moveTolerance) -> Bool {
        abs(a.height - b.height) <= tolerance
            && !MenuBarPanelPlacement.needsMove(from: a.origin, to: b.origin, tolerance: tolerance)
    }
}
