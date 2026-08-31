import AppKit
import Foundation

/// Where to put a floating panel.
///
/// Extracted because the Shelf is the **third** caller of the same two-line idiom — the clipboard
/// picker and the toast presenter each had their own copy of "the screen the pointer is on, then its
/// visibleFrame". Two is a coincidence; three is a helper.
enum ScreenPlacement {

    /// The screen the pointer is on, which is the one the user is working on — not
    /// `NSScreen.main`, which is the one with key focus and can be a different display entirely.
    static func screenUnderPointer(_ screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Top-left corner for a panel of `size` placed at `point`, clamped so it never opens
    /// off-screen — near a screen edge or the menu bar is exactly where a pointer often is.
    ///
    /// Pure, so the clamping is testable without a real display.
    static func topLeft(
        forSize size: CGSize,
        at point: CGPoint,
        in visible: CGRect,
        offset: CGFloat = 8
    ) -> CGPoint {
        var x = point.x + offset
        var y = point.y - offset

        if x + size.width > visible.maxX { x = max(visible.minX, point.x - size.width - offset) }
        if x < visible.minX { x = visible.minX }
        // `y` is the *top* edge, so the panel extends downward from it.
        if y - size.height < visible.minY { y = min(visible.maxY, point.y + size.height + offset) }
        if y > visible.maxY { y = visible.maxY }

        return CGPoint(x: x, y: y)
    }

    /// Which edge of a screen a point is within `thickness` of, if any.
    ///
    /// Pure: this is what the invisible edge strip uses to decide it has been entered, and it needs
    /// to be right on a multi-display setup where "the left edge" is not x == 0.
    static func edge(at point: CGPoint, in frame: CGRect, thickness: CGFloat) -> Edge? {
        guard frame.contains(point) else { return nil }
        if point.x - frame.minX <= thickness { return .left }
        if frame.maxX - point.x <= thickness { return .right }
        if frame.maxY - point.y <= thickness { return .top }
        if point.y - frame.minY <= thickness { return .bottom }
        return nil
    }

    enum Edge: String, CaseIterable, Identifiable, Codable {
        case left, right, top, bottom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            case .top: return "Top"
            case .bottom: return "Bottom"
            }
        }
    }

    /// The strip of screen that listens for a drag, for a given edge.
    static func strip(for edge: Edge, in frame: CGRect, thickness: CGFloat) -> CGRect {
        switch edge {
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        case .right:
            return CGRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        case .top:
            return CGRect(x: frame.minX, y: frame.maxY - thickness, width: frame.width, height: thickness)
        case .bottom:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        }
    }
}
