import CoreGraphics
import Foundation

/// A stretch where the pointer's surroundings are dimmed, to say "look here".
///
/// **Distinct from `StudioMask.Mode.highlight`, on purpose.** That is a hand-drawn rectangle with a
/// time range: it does not move, and it has to be placed and sized. This one is centred on the
/// cursor's own recorded position, so it tracks whatever was being demonstrated without anybody
/// drawing a box — which is the thing that was missing, since `CursorSettings` is entirely global
/// and could not express "now" at all.
struct PointerHighlight: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    /// Of the frame's **shorter** side. Taking it from the width would make one setting a very
    /// different spotlight on a wide recording than on a tall one.
    var radiusFraction: Double = 0.14
    /// How far everything outside the circle is dimmed, 0…1.
    var dimming: Double = 0.55
    /// Faded in and out over this, at both ends. A spotlight that appears between two frames reads
    /// as a flash — the same reason the camera's layout changes are blended.
    var transition: TimeInterval = 0.25

    static let minimumDuration: TimeInterval = 0.4
}

/// Resolving the pointer highlights into one circle.
enum PointerSpotlight {

    struct State: Equatable {
        /// Recording pixel space, like `ClickEvent.point`.
        var centre: CGPoint
        var radius: CGFloat
        var dimming: Double
    }

    /// - Parameter cursor: the pointer's recorded position at `t`, or nil if it is not known —
    ///   in which case there is nothing to point at, and inventing a centre would put the
    ///   spotlight in a corner.
    static func state(at t: TimeInterval, highlights: [PointerHighlight],
                      cursor: CGPoint?, frameSize: CGSize) -> State? {
        guard let cursor,
              frameSize.width > 0, frameSize.height > 0,
              // The first that covers this moment wins, so overlapping spotlights never multiply
              // into darkness.
              let spot = highlights.first(where: { t >= $0.start && t < $0.end })
        else { return nil }

        let shorter = min(frameSize.width, frameSize.height)
        return State(centre: cursor,
                     radius: shorter * CGFloat(max(0.01, spot.radiusFraction)),
                     dimming: spot.dimming * Self.fade(at: t, spot: spot))
    }

    /// 1 while the spotlight holds, ramping from 0 at each edge.
    private static func fade(at t: TimeInterval, spot: PointerHighlight) -> Double {
        let ramp = max(0.0001, min(spot.transition, (spot.end - spot.start) / 2))
        let sinceStart = t - spot.start
        let untilEnd = spot.end - t
        let raw = min(sinceStart / ramp, untilEnd / ramp)
        return ZoomEase.smooth.value(min(1, max(0, raw)))
    }
}
