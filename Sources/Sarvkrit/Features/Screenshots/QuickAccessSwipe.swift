import CoreGraphics
import Foundation

/// Tells a flick toward the edge of the screen apart from a drag into another app.
///
/// Both gestures start the same way — mouse down on the thumbnail, then movement — so something
/// has to decide, and it has to decide on the *first* few points of travel: once
/// `beginDraggingSession` is called the drag belongs to AppKit and the chance is gone.
///
/// The rule: predominantly sideways, and heading *out* past the nearer vertical screen edge. A
/// capture parked at the bottom-right is dismissed by throwing it to the right, which is the
/// direction nothing else means. Everything else — down, up, diagonal, or sideways *inward*
/// toward the middle of the screen where other apps are — is a drag-out, because that is the
/// gesture that must never be lost. Getting this backwards loses a file the user was dropping
/// into Slack, so the tie always goes to the drag.
enum QuickAccessSwipe {

    enum Decision: Equatable {
        /// Not enough travel yet to tell. Wait for the next event rather than guessing.
        case undecided
        case dismiss
        case dragOut
    }

    /// How far the pointer must travel before either verdict is allowed.
    static let threshold: CGFloat = 12

    /// How much more sideways than vertical a flick has to be. 2:1 rather than something tighter
    /// because a hand throwing something sideways drifts, and a rejected swipe becomes a
    /// surprise file drag.
    static let sidewaysRatio: CGFloat = 2

    /// - Parameters:
    ///   - start: where the press began, in global screen points.
    ///   - current: where the pointer is now, in global screen points.
    ///   - panel: the overlay's frame, for deciding which edge it is parked against.
    ///   - screen: the frame of the screen it is parked on.
    static func decide(from start: CGPoint, to current: CGPoint,
                       panel: CGRect, screen: CGRect) -> Decision {
        let dx = current.x - start.x
        let dy = current.y - start.y
        guard max(abs(dx), abs(dy)) >= threshold else { return .undecided }
        guard abs(dx) >= abs(dy) * sidewaysRatio else { return .dragOut }

        // Which vertical edge it is parked against, by whichever it is nearer.
        let towardsRight = (panel.midX - screen.minX) > (screen.maxX - panel.midX)
        let outward = towardsRight ? dx > 0 : dx < 0
        return outward ? .dismiss : .dragOut
    }
}
