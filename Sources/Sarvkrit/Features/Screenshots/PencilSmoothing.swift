import CoreGraphics
import Foundation

/// Turning raw mouse samples into a stroke that looks drawn rather than traced.
///
/// **Both algorithms, in this order.** Ramer–Douglas–Peucker first, to throw away sampling noise;
/// Catmull-Rom second, to interpolate what survives. RDP alone leaves visible corners where the
/// samples were kept. Catmull-Rom alone amplifies hand jitter into wobble and stores hundreds of
/// points per stroke, which bloats every saved document. Together, a 400-point stroke becomes
/// roughly 25 stored points that render as a smooth curve.
enum PencilSmoothing {

    /// Ramer–Douglas–Peucker.
    ///
    /// - Parameter epsilon: in image pixels. The editor passes `1.5 / zoom`, so drawing while
    ///   zoomed in keeps the detail the user can actually see.
    static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, epsilon > 0 else { return points }

        var furthest = 0
        var maximum: CGFloat = 0
        let first = points[0], last = points[points.count - 1]
        for index in 1..<(points.count - 1) {
            let distance = perpendicularDistance(points[index], from: first, to: last)
            if distance > maximum {
                maximum = distance
                furthest = index
            }
        }

        guard maximum > epsilon else { return [first, last] }
        let left = simplify(Array(points[0...furthest]), epsilon: epsilon)
        let right = simplify(Array(points[furthest...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// Distance from a point to the segment a→b. Handles the degenerate a == b case, which
    /// happens whenever the pointer doesn't move between samples.
    static func perpendicularDistance(_ point: CGPoint,
                                      from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    struct CubicSegment: Equatable {
        let from: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    /// Catmull-Rom through every point, as cubic Béziers `CGPath` can draw.
    ///
    /// The curve passes *through* the input points rather than being pulled toward them, which is
    /// what makes it right for a freehand stroke — the line has to go where the hand went.
    static func catmullRomBeziers(_ points: [CGPoint], tension: CGFloat = 0.5) -> [CubicSegment] {
        guard points.count >= 2 else { return [] }
        if points.count == 2 {
            return [CubicSegment(from: points[0], control1: points[0],
                                 control2: points[1], to: points[1])]
        }

        var segments: [CubicSegment] = []
        for index in 0..<(points.count - 1) {
            // Duplicate the ends rather than wrapping: a stroke is open, and wrapping would curve
            // the first segment toward the last point.
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]

            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension / 3,
                             y: p1.y + (p2.y - p0.y) * tension / 3)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension / 3,
                             y: p2.y - (p3.y - p1.y) * tension / 3)
            segments.append(CubicSegment(from: p1, control1: c1, control2: c2, to: p2))
        }
        return segments
    }

    /// Simplify then flatten, for hit-testing a stored stroke.
    static func polyline(_ points: [CGPoint], segmentsPerCurve: Int = 8) -> [CGPoint] {
        let curves = catmullRomBeziers(points)
        guard !curves.isEmpty else { return points }
        var result: [CGPoint] = [curves[0].from]
        for curve in curves {
            for step in 1...segmentsPerCurve {
                let t = CGFloat(step) / CGFloat(segmentsPerCurve)
                result.append(pointOnCubic(curve, t: t))
            }
        }
        return result
    }

    static func pointOnCubic(_ segment: CubicSegment, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(
            x: a * segment.from.x + b * segment.control1.x + c * segment.control2.x + d * segment.to.x,
            y: a * segment.from.y + b * segment.control1.y + c * segment.control2.y + d * segment.to.y)
    }
}
