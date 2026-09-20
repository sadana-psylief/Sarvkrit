import Foundation

/// The curve a zoom travels along.
///
/// **A critically damped spring, not `easeInOut`.** The reference product's zooms feel like the
/// frame has weight, and a symmetric cubic does not: it accelerates and decelerates equally, which
/// reads as mechanical. A damped spring covers most of the distance early and settles into the
/// target, which is what the eye expects of something being moved rather than animated.
///
/// Critically damped specifically — `ζ = 1` — so it never overshoots. A zoom that sails past its
/// level and springs back is charming exactly once and seasickening over a five-minute demo.
enum ZoomEase: String, Codable, CaseIterable, Equatable {
    case smooth
    case linear
    /// Cut straight to the target. For a zoom that begins on a cut, where animating in would show
    /// a moment of the wrong framing.
    case instant

    /// Stiffness. Higher settles sooner; 6 puts roughly 98% of the travel inside the duration,
    /// which is why the normalisation below is needed at all.
    private static let stiffness = 6.0

    /// Eased progress for linear progress `t`.
    ///
    /// **Both ends land exactly.** The spring's natural value at `t = 1` is about 0.983, and
    /// leaving it there would stop every zoom a fraction short of its level — with a visible jolt
    /// when the next segment takes over from a different value. Dividing by that same constant is
    /// exact in floating point (`x / x == 1`), so the endpoint is not merely close.
    func value(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        switch self {
        case .linear:
            return t
        case .instant:
            return t <= 0 ? 0 : 1
        case .smooth:
            return Self.spring(t) / Self.spring(1)
        }
    }

    /// The step response of a critically damped second-order system, from 0 to ~1.
    private static func spring(_ t: Double) -> Double {
        1 - (1 + stiffness * t) * exp(-stiffness * t)
    }

    func interpolate(from: Double, to: Double, progress: Double) -> Double {
        from + (to - from) * value(progress)
    }

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .linear: return "Linear"
        case .instant: return "Instant"
        }
    }
}
