import CoreGraphics
import Foundation

/// Where the post-capture thumbnails sit, and when they go away.
///
/// Pure, because the interesting cases are all arithmetic you would otherwise verify by taking
/// screenshots and watching a corner of the screen for eight seconds.
enum QuickAccessPlacement {

    /// Raw values are persisted.
    enum Corner: String, Codable, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }

        var title: String {
            switch self {
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }
    }

    /// Bottom-left origin for a panel of `size` in the chosen corner of `visibleFrame`.
    ///
    /// `visibleFrame` rather than `frame`, so the overlay clears the menu bar and the Dock — it is
    /// a thing you are meant to click, unlike the capture overlay which covers them deliberately.
    static func origin(forSize size: CGSize,
                       corner: Corner,
                       in visibleFrame: CGRect,
                       inset: CGFloat = 16) -> CGPoint {
        // A panel bigger than the screen is clamped rather than pushed off it. Rare, but the
        // alternative is an overlay you cannot see or dismiss.
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft, .bottomLeft:   x = visibleFrame.minX + inset
        case .topRight, .bottomRight: x = visibleFrame.maxX - width - inset
        }
        switch corner {
        case .topLeft, .topRight:         y = visibleFrame.maxY - height - inset
        case .bottomLeft, .bottomRight:   y = visibleFrame.minY + inset
        }
        return CGPoint(x: min(max(x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - width)),
                       y: min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - height)))
    }

    /// How far the *n*th thumbnail is offset from the first, so a burst of captures stacks
    /// visibly instead of landing exactly on top of each other.
    ///
    /// Stacking runs *into* the screen from the chosen corner, and stops before it would leave the
    /// visible frame — beyond that the newest simply replaces the oldest, which is better than a
    /// pile that walks off the edge.
    static func stackOffset(forIndex index: Int,
                            size: CGSize,
                            corner: Corner,
                            in visibleFrame: CGRect,
                            spacing: CGFloat = 8,
                            inset: CGFloat = 16) -> CGSize? {
        guard index >= 0 else { return nil }
        let step = size.height + spacing
        let available = visibleFrame.height - inset * 2 - size.height
        guard CGFloat(index) * step <= available else { return nil }

        switch corner {
        case .topLeft, .topRight:
            // Stacking downward from the top corner.
            return CGSize(width: 0, height: -CGFloat(index) * step)
        case .bottomLeft, .bottomRight:
            return CGSize(width: 0, height: CGFloat(index) * step)
        }
    }
}

/// When an overlay closes on its own.
///
/// Pure so "hovering pauses the countdown" is a test rather than something you sit and watch.
enum QuickAccessTimer {

    /// Seconds left, or nil when auto-close is off.
    ///
    /// Hovering pauses rather than cancels: the point of the pause is to let someone read or aim
    /// at the thumbnail, and cancelling outright would leave overlays on screen forever after an
    /// accidental pass of the pointer.
    static func remaining(now: Date,
                          shownAt: Date,
                          duration: TimeInterval?,
                          hoveredSince: Date?) -> TimeInterval? {
        guard let duration else { return nil }
        // While hovering, the clock stops at whatever it read when the pointer arrived.
        let effectiveNow = hoveredSince ?? now
        return max(0, duration - effectiveNow.timeIntervalSince(shownAt))
    }

    static func hasExpired(now: Date,
                           shownAt: Date,
                           duration: TimeInterval?,
                           hoveredSince: Date?) -> Bool {
        guard let remaining = remaining(now: now, shownAt: shownAt,
                                        duration: duration, hoveredSince: hoveredSince)
        else { return false }
        return remaining <= 0
    }
}
