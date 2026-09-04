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

    /// The largest a pin may grow, as a fraction of the display it is on.
    ///
    /// A pin is a reference you look at beside your work. One filling the screen is not a
    /// reference, and one larger than the screen cannot be closed.
    static let maximumFraction: CGFloat = 0.9
    /// Never more transparent than this. At zero a pin is invisible but still on screen — and
    /// while Lock Mode is off it still takes clicks, so the user would be left with a dead patch
    /// of screen they can neither see nor dismiss.
    static let minimumOpacity: Double = 0.15

    /// Resize by dragging a corner, keeping the opposite corner fixed.
    ///
    /// - Parameters:
    ///   - delta: the change *since the last event*, not since the drag began. A caller that
    ///     passes the cumulative translation compounds it — which is how a hundred-point drag once
    ///     grew a window by a thousand.
    ///   - displays: the screens to stay inside. Empty means no bound, which only happens while
    ///     displays are being reconfigured.
    static func resized(_ frame: CGRect, by delta: CGSize,
                        preservingAspect: Bool,
                        displays: [CGRect] = []) -> CGRect {
        let aspect = frame.height > 0 ? frame.width / frame.height : 1
        var width = frame.width + delta.width
        var height = preservingAspect ? width / max(aspect, 0.0001) : frame.height + delta.height

        // Both sides clear the floor, and the ratio survives it. Clamping each side on its own
        // squashes a 2:1 pin to 1:1 the moment either edge hits the minimum.
        (width, height) = clampToMinimum(width: width, height: height,
                                         aspect: aspect, preservingAspect: preservingAspect)

        // A ceiling, which there was not one of. Together with a caller that compounded its
        // deltas, a pin could grow past the display until its close button was off the edge — an
        // always-on-top window with no way to reach its own controls.
        if let bounds = displays.first(where: { $0.intersects(frame) }) ?? displays.first {
            (width, height) = clamp(width: width, height: height, aspect: aspect,
                                    preservingAspect: preservingAspect,
                                    to: CGSize(width: bounds.width * maximumFraction,
                                               height: bounds.height * maximumFraction))
            // The fraction bounds the *size*; this bounds the *position*. A pin near the right
            // edge can satisfy the fraction and still push its own controls past the screen,
            // because the top-left corner is the one that stays put.
            (width, height) = clamp(width: width, height: height, aspect: aspect,
                                    preservingAspect: preservingAspect,
                                    to: CGSize(width: bounds.maxX - frame.minX,
                                               height: frame.maxY - bounds.minY))
            (width, height) = clampToMinimum(width: width, height: height,
                                             aspect: aspect, preservingAspect: preservingAspect)
        }

        // Anchored top-left, so the corner being dragged is the one that moves.
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    private static func clampToMinimum(width: CGFloat, height: CGFloat, aspect: CGFloat,
                                       preservingAspect: Bool) -> (CGFloat, CGFloat) {
        var width = width, height = height
        guard preservingAspect else {
            return (max(minimumSide, width), max(minimumSide, height))
        }
        if width < minimumSide { width = minimumSide; height = width / max(aspect, 0.0001) }
        if height < minimumSide { height = minimumSide; width = height * aspect }
        return (width, height)
    }

    private static func clamp(width: CGFloat, height: CGFloat, aspect: CGFloat,
                              preservingAspect: Bool, to ceiling: CGSize) -> (CGFloat, CGFloat) {
        var width = width, height = height
        guard preservingAspect else {
            return (min(width, max(minimumSide, ceiling.width)),
                    min(height, max(minimumSide, ceiling.height)))
        }
        if width > ceiling.width { width = ceiling.width; height = width / max(aspect, 0.0001) }
        if height > ceiling.height { height = ceiling.height; width = height * aspect }
        return (width, height)
    }

    // `nudged` used to live here — an arrow-key move that kept a pin reachable, with tests, and
    // no caller anywhere in `Sources/`. A pinned panel is deliberately `acceptsKey: false`, so it
    // receives no key events and never could have had one. Dead safety code is worse than none:
    // it reads as a protection that is in place. The rule it encoded — a pin must stay reachable —
    // now lives in `resized` above, where something actually calls it.

    static func clampedOpacity(_ opacity: Double) -> Double {
        min(1, max(minimumOpacity, opacity))
    }
}
