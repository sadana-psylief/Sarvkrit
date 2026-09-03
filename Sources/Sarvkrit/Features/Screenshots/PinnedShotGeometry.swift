import CoreGraphics
import Foundation

/// Resizing and nudging a pinned screenshot.
///
/// Pure, and two of these rules exist because getting them wrong makes a pinned window
/// *unrecoverable* — it is always on top, so a pin that has walked off every display or faded to
/// nothing is one the user cannot reach to close.
enum PinnedShotGeometry {

    /// Never smaller than this. A pin shrunk to a few pixels has no visible close button.
    static let minimumSide: CGFloat = 60
    /// Never more transparent than this. At zero a pin is invisible but still on screen — and
    /// while Lock Mode is off it still takes clicks, so the user would be left with a dead patch
    /// of screen they can neither see nor dismiss.
    static let minimumOpacity: Double = 0.15

    /// Resize by dragging a corner, keeping the opposite corner fixed.
    static func resized(_ frame: CGRect,
                        by delta: CGSize,
                        preservingAspect: Bool) -> CGRect {
        let aspect = frame.height > 0 ? frame.width / frame.height : 1
        var width = frame.width + delta.width
        var height = preservingAspect ? width / max(aspect, 0.0001) : frame.height + delta.height

        width = max(width, minimumSide)
        height = max(height, minimumSide)
        if preservingAspect {
            // Re-derive after clamping, or hitting the floor on one axis silently changes the
            // ratio the caller asked to preserve.
            if width / aspect < minimumSide {
                height = minimumSide
                width = minimumSide * aspect
            } else {
                height = width / aspect
            }
        }

        // The origin is bottom-left and the drag grows down-right, so y moves with the height.
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    /// Arrow-key nudge, kept reachable.
    ///
    /// Clamped so at least `visibleMargin` of the pin stays within the union of the displays. A
    /// pin nudged entirely off-screen is always-on-top and therefore impossible to get back to.
    static func nudged(_ frame: CGRect,
                       by delta: CGSize,
                       constrainedTo displays: [CGRect],
                       visibleMargin: CGFloat = 40) -> CGRect {
        let moved = frame.offsetBy(dx: delta.width, dy: delta.height)
        guard !displays.isEmpty else { return moved }

        let stillReachable = displays.contains { display in
            let overlap = display.intersection(moved)
            return !overlap.isNull
                && overlap.width >= min(visibleMargin, moved.width)
                && overlap.height >= min(visibleMargin, moved.height)
        }
        return stillReachable ? moved : frame
    }

    static func clampedOpacity(_ opacity: Double) -> Double {
        min(1, max(minimumOpacity, opacity))
    }
}
