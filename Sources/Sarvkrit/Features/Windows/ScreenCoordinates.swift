import CoreGraphics
import Foundation

/// Converts between the two coordinate systems macOS uses for windows.
///
/// `NSScreen` measures from the **bottom-left of the primary display, Y increasing upward**.
/// Accessibility measures from the **top-left of the primary display, Y increasing downward**.
/// Get this wrong and windows land mirrored vertically, or on the wrong display, and it looks like
/// the geometry is broken when it isn't.
///
/// **The sub-bug inside the bug:** the flip always uses the **primary** display's height, never the
/// target screen's. On a single-display Mac the two are identical, so using the wrong one is
/// correct-by-accident until a second monitor appears. That's why this is a separate pure function
/// with tests against synthetic arrangements — on a one-screen machine there is no other defence.
enum ScreenCoordinates {

    /// Cocoa (bottom-left, Y up) → Accessibility (top-left, Y down).
    static func toAccessibility(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Accessibility (top-left, Y down) → Cocoa (bottom-left, Y up).
    ///
    /// The same arithmetic in reverse: the conversion is its own inverse.
    static func toCocoa(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - (rect.minY + rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    /// Which of the given screens a rect mostly sits on, by overlapping area.
    ///
    /// Area rather than the origin: a window straddling two displays belongs to whichever shows
    /// more of it, which is what a person would say too. Falls back to the first screen when a
    /// window overlaps none of them — dragged off-screen, or a display just unplugged.
    static func screen(containing rect: CGRect, screens: [CGRect]) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        let best = screens.max { a, b in
            a.intersection(rect).area < b.intersection(rect).area
        }
        guard let best, best.intersection(rect).area > 0 else { return screens[0] }
        return best
    }

    /// The screen after `current` in the given order, wrapping around. Used by next/previous
    /// display.
    static func adjacentScreen(to current: CGRect, screens: [CGRect], forward: Bool) -> CGRect? {
        guard screens.count > 1, let index = screens.firstIndex(of: current) else { return nil }
        let next = forward
            ? (index + 1) % screens.count
            : (index - 1 + screens.count) % screens.count
        return screens[next]
    }

    /// Moves a rect onto another screen, keeping its relative position and proportions rather than
    /// its absolute size — displays differ in resolution, and a window that filled half of a small
    /// screen should fill half of the big one.
    static func translate(_ rect: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        return CGRect(
            x: destination.minX + (rect.minX - source.minX) * scaleX,
            y: destination.minY + (rect.minY - source.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
