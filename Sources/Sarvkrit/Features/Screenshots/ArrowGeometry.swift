import CoreGraphics
import Foundation

/// The shape of an arrow.
///
/// **One filled path, not a stroked line with a triangle stuck on the end.** The stuck-on version
/// is what most drawing code does and it always looks like clip art: the shaft is a constant-width
/// rectangle, the join where the head meets it shows as a step, and the barbs form a flat-backed
/// wedge. The difference is immediately visible at any size.
///
/// This builds the outline instead:
///
/// - **The shaft tapers.** It is `tailWidth` at the tail and widens toward the neck, so the mark
///   has direction even before you notice the head. A pen or a brush does this naturally; a
///   stroked line cannot.
/// - **The head is swept back.** Its trailing edge is concave — the barbs curve toward the tip
///   rather than cutting straight across — which is what stops it reading as a triangle.
/// - **The whole thing is one closed path**, so there is no seam between shaft and head and no
///   double-darkening where they overlap at low opacity.
///
/// Proportions are expressed as multiples of the stroke width so an arrow looks like itself at
/// every thickness, and are clamped against the arrow's own length so a short arrow becomes a neat
/// dart rather than a head with no shaft.
enum ArrowGeometry {

    struct Metrics {
        /// Half-width at the very tail. Small but non-zero: a true point looks broken when the
        /// arrow is short.
        var tailWidth: CGFloat
        /// Half-width where the shaft meets the head.
        var neckWidth: CGFloat
        /// How far back the head reaches from the tip.
        var headLength: CGFloat
        /// Half-width of the head at its widest.
        var headWidth: CGFloat
        /// How far the trailing edge of the head is pulled toward the tip, as a fraction of
        /// `headLength`. Zero is a flat-backed triangle; this is what makes it sweep.
        var headSweep: CGFloat
    }

    /// Proportions per style, in multiples of the stroke width.
    static func metrics(for head: ArrowElement.Head, strokeWidth: CGFloat,
                        length: CGFloat) -> Metrics {
        let w = max(strokeWidth, 0.5)
        var metrics: Metrics
        switch head {
        case .filled:
            metrics = Metrics(tailWidth: w * 0.16, neckWidth: w * 0.5,
                              headLength: w * 2.8, headWidth: w * 1.22, headSweep: 0.10)
        case .curved:
            metrics = Metrics(tailWidth: w * 0.14, neckWidth: w * 0.46,
                              headLength: w * 2.7, headWidth: w * 1.18, headSweep: 0.12)
        case .thin:
            // A finer dart: barely any taper, a longer and narrower head.
            metrics = Metrics(tailWidth: w * 0.32, neckWidth: w * 0.4,
                              headLength: w * 3.1, headWidth: w * 0.95, headSweep: 0.08)
        case .open:
            // Blunter and heavier: an even shaft into a wide, shallow head.
            metrics = Metrics(tailWidth: w * 0.46, neckWidth: w * 0.5,
                              headLength: w * 2.2, headWidth: w * 1.32, headSweep: 0.06)
        }

        // A short arrow must not be all head, and a thick one must not be either — at 26pt the
        // untamed proportions produced a head nearly half the arrow, which reads as a signpost
        // rather than a mark on a screenshot.
        // Purely a fraction of the length, with **no absolute floor**. A floor sounds right — it
        // keeps a thick short arrow from losing its head — but it inverts on the degenerate case:
        // a 40pt-wide arrow drawn 24pt long got a 36pt head, so the head was longer than the
        // arrow. A short arrow should simply be a small dart.
        let maximumHead = length * 0.4
        if metrics.headLength > maximumHead {
            let scale = maximumHead / metrics.headLength
            metrics.headLength *= scale
            metrics.headWidth *= scale
        }
        // Independently of the length cap, hold the head's aspect: a head wider than it is long
        // stops looking like a point and starts looking like a fin.
        metrics.headWidth = min(metrics.headWidth, metrics.headLength * 0.62)
        metrics.neckWidth = min(metrics.neckWidth, metrics.headWidth * 0.66)
        return metrics
    }

    /// The closed outline of an arrow from `start` to `end`.
    ///
    /// - Parameter curvature: perpendicular offset of the Bézier control point from the chord
    ///   midpoint. Zero draws a straight arrow.
    static func path(from start: CGPoint, to end: CGPoint,
                     curvature: CGFloat,
                     head: ArrowElement.Head,
                     strokeWidth: CGFloat) -> CGPath {
        let spine = spinePoints(from: start, to: end, curvature: curvature)
        let length = polylineLength(spine)
        guard length > 0.001 else { return CGMutablePath() }

        let metrics = metrics(for: head, strokeWidth: strokeWidth, length: length)
        let neckDistance = max(length - metrics.headLength, 0.001)

        // Walk the spine to the neck, offsetting left and right by a width that grows along the
        // way. Following the spine rather than the chord is what lets a curved arrow taper
        // correctly instead of pinching where the bow is tightest.
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        var travelled: CGFloat = 0
        var neckPoint = spine[0]
        var neckNormal = CGPoint(x: 0, y: 0)

        for index in 0..<spine.count {
            if index > 0 {
                travelled += distance(spine[index - 1], spine[index])
            }
            guard travelled <= neckDistance else { break }
            let t = neckDistance > 0 ? travelled / neckDistance : 0
            // Ease the taper so the widening is gentle at the tail and firmer near the neck,
            // which is how a brush loads. Linear looks mechanical.
            let eased = t * t * (3 - 2 * t)
            let halfWidth = metrics.tailWidth + (metrics.neckWidth - metrics.tailWidth) * eased
            let normal = self.normal(of: spine, at: index)
            left.append(CGPoint(x: spine[index].x + normal.x * halfWidth,
                                y: spine[index].y + normal.y * halfWidth))
            right.append(CGPoint(x: spine[index].x - normal.x * halfWidth,
                                 y: spine[index].y - normal.y * halfWidth))
            neckPoint = spine[index]
            neckNormal = normal
        }

        if left.isEmpty {
            left = [CGPoint(x: start.x, y: start.y)]
            right = left
            neckPoint = start
            neckNormal = normal(of: spine, at: 0)
        }

        // The head, built off the final direction so it points along the curve.
        let tip = spine[spine.count - 1]
        let direction = self.direction(of: spine)
        let backCentre = CGPoint(x: tip.x - direction.x * metrics.headLength,
                                 y: tip.y - direction.y * metrics.headLength)
        let headNormal = CGPoint(x: -direction.y, y: direction.x)

        let barbLeft = CGPoint(x: backCentre.x + headNormal.x * metrics.headWidth,
                               y: backCentre.y + headNormal.y * metrics.headWidth)
        let barbRight = CGPoint(x: backCentre.x - headNormal.x * metrics.headWidth,
                                y: backCentre.y - headNormal.y * metrics.headWidth)

        let neckLeft = CGPoint(x: neckPoint.x + neckNormal.x * metrics.neckWidth,
                               y: neckPoint.y + neckNormal.y * metrics.neckWidth)
        let neckRight = CGPoint(x: neckPoint.x - neckNormal.x * metrics.neckWidth,
                                y: neckPoint.y - neckNormal.y * metrics.neckWidth)

        /// Control point for a barb-to-neck edge, pulled toward the tip so the edge is concave.
        ///
        /// **Applied to both sides.** The first version put a single notch on the right-hand edge
        /// only, which made the head lopsided — subtle at a hairline, obviously wrong at 26pt.
        func sweptControl(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let pull = metrics.headLength * metrics.headSweep
            return CGPoint(x: (a.x + b.x) / 2 + direction.x * pull,
                           y: (a.y + b.y) / 2 + direction.y * pull)
        }

        /// Control point for a barb-to-tip edge, bowed very slightly outward so the leading edges
        /// are not dead straight. Straight edges are what make a head read as clip art.
        func leadingControl(_ barb: CGPoint, sign: CGFloat) -> CGPoint {
            CGPoint(x: (barb.x + tip.x) / 2 + headNormal.x * metrics.headWidth * 0.08 * sign,
                    y: (barb.y + tip.y) / 2 + headNormal.y * metrics.headWidth * 0.08 * sign)
        }

        let path = CGMutablePath()
        path.move(to: left.first ?? start)
        for point in left.dropFirst() { path.addLine(to: point) }
        path.addQuadCurve(to: barbLeft, control: sweptControl(neckLeft, barbLeft))
        path.addQuadCurve(to: tip, control: leadingControl(barbLeft, sign: 1))
        path.addQuadCurve(to: barbRight, control: leadingControl(barbRight, sign: -1))
        path.addQuadCurve(to: neckRight, control: sweptControl(barbRight, neckRight))
        for point in right.reversed().dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    // MARK: - Spine

    /// The arrow's centre line, flattened. A straight arrow is two points; a curved one is a
    /// quadratic Bézier sampled finely enough that the taper reads smoothly.
    static func spinePoints(from start: CGPoint, to end: CGPoint,
                            curvature: CGFloat, steps: Int = 48) -> [CGPoint] {
        guard abs(curvature) > 0.01 else {
            // Still sampled, so the taper has somewhere to happen.
            return (0...steps).map { step in
                let t = CGFloat(step) / CGFloat(steps)
                return CGPoint(x: start.x + (end.x - start.x) * t,
                               y: start.y + (end.y - start.y) * t)
            }
        }
        return AnnotationGeometry.quadratic(from: start, to: end,
                                            curvature: curvature, steps: steps)
    }

    private static func normal(of points: [CGPoint], at index: Int) -> CGPoint {
        let a = points[max(index - 1, 0)]
        let b = points[min(index + 1, points.count - 1)]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.0001)
        return CGPoint(x: -dy / length, y: dx / length)
    }

    private static func direction(of points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return CGPoint(x: 1, y: 0) }
        // Averaged over the last few samples: a single segment on a finely sampled curve is short
        // enough that rounding makes the head wobble.
        let tip = points[points.count - 1]
        let back = points[max(points.count - 6, 0)]
        let dx = tip.x - back.x, dy = tip.y - back.y
        let length = max(hypot(dx, dy), 0.0001)
        return CGPoint(x: dx / length, y: dy / length)
    }

    static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return (1..<points.count).reduce(0) { $0 + distance(points[$1 - 1], points[$1]) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
