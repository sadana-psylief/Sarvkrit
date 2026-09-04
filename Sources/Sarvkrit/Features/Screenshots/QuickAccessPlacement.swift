import CoreGraphics
import Foundation

/// Which corner the post-capture thumbnails live in.
///
/// The placement arithmetic that used to live here was replaced by `QuickAccessController`'s
/// stacking pass, which accumulates real panel heights instead of multiplying an index by a fixed
/// pitch — captures are different shapes, so a fixed pitch left gaps and overlaps. Only the corner
/// itself is shared, because it is a persisted user setting.
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
