import CoreGraphics
import Foundation

/// The shape of an arrow.
///
/// **Built to measurements taken off a reference arrow, not to taste.** The first version here was
/// a stroked line with a triangle on the end, which always reads as clip art; the second was my
/// own guess at a tapered shape and grew spurs. These proportions come from measuring a real one,
/// with `W` throughout meaning the shaft's full width where it meets the head — the number the
/// user is setting when they choose a thickness.
///
/// The geometry that matters, arrow pointing +x with the shaft/head junction at the origin:
///
/// - **tip** at `(3.0W, 0)`
/// - **barb tips** at `(-0.3W, ±1.425W)` — *behind* the junction, which is what makes the head
///   look swept rather than like a triangle sitting on a stick
/// - **shaft edge at the junction** `(0, ±0.5W)`, tapering **linearly** back to `±0.175W` at the
///   tail, which ends in a semicircular cap
///
/// The back edge is a straight line from each barb tip forward to the shaft edge. Curving it, as
/// an earlier attempt did, produces a fishtail.
enum ArrowGeometry {

    /// How an arrow should be painted. Two of the four styles are outlines and two are strokes,
    /// so the caller cannot just always fill.
    enum Shape {
        case fill(CGPath)
        case stroke(CGPath, lineWidth: CGFloat)
    }

    struct Metrics {
        /// Half-width at the tail.
        var tailHalf: CGFloat
        /// Half-width where the shaft meets the head.
        var neckHalf: CGFloat
        /// Junction plane to tip.
        var headLength: CGFloat
        /// Half the barb-to-barb span.
        var headHalf: CGFloat
        /// How far the barb tips sit *behind* the junction.
        var barbSetback: CGFloat
    }

    /// Proportions in multiples of the shaft width, per the measurements above.
    static func metrics(for head: ArrowElement.Head, strokeWidth: CGFloat,
                        length: CGFloat) -> Metrics {
        let w = max(strokeWidth, 0.5)
        var metrics: Metrics
        switch head {
        case .filled, .curved:
            metrics = Metrics(tailHalf: w * 0.175, neckHalf: w * 0.5,
                              headLength: w * 3.0, headHalf: w * 1.425, barbSetback: w * 0.3)
        case .thin:
            // Less taper and a narrower head: a dart rather than a brush stroke.
            metrics = Metrics(tailHalf: w * 0.34, neckHalf: w * 0.45,
                              headLength: w * 3.2, headHalf: w * 1.15, barbSetback: w * 0.22)
        case .open:
            // Handled as a stroked chevron; these are only used for hit-testing bounds.
            metrics = Metrics(tailHalf: w * 0.5, neckHalf: w * 0.5,
                              headLength: w * 3.3, headHalf: w * 1.65, barbSetback: 0)
        }

        // The shaft must survive. Below five widths of length there is no room for a full head, so
        // the whole head scales down rather than swallowing the arrow — an earlier absolute floor
        // did the opposite and gave a 24pt arrow a 36pt head.
        let minimumShaft = w * 2.0
        // Two competing needs: leave room for a shaft, and never let the head vanish. Taking the
        // larger keeps both — without the second term a 30pt arrow at 16pt wide came out as a
        // plain line with no head at all, which is worse than a slightly stubby one.
        let maximumHead = max(length - minimumShaft, length * 0.45)
        if metrics.headLength > maximumHead {
            // No lower clamp on the scale: one used to override `maximumHead` itself and hand a
            // 24pt arrow an 18pt head, which is the very thing the cap exists to stop.
            let scale = min(1, maximumHead / metrics.headLength)
            metrics.headLength *= scale
            metrics.headHalf *= scale
            metrics.barbSetback *= scale
            metrics.neckHalf = min(metrics.neckHalf, metrics.headHalf * 0.62)
            metrics.tailHalf = min(metrics.tailHalf, metrics.neckHalf)
        }
        return metrics
    }

    /// The bow a `.curved` arrow gets when the user hasn't dragged one in.
    ///
    /// **Without this, "curved" is not a style at all** — it would render identically to `.filled`
    /// until the curve handle was touched, so the button would appear to do nothing. A sagitta of
    /// about 7% of the chord matches the reference; a quadratic reaches half its control offset,
    /// hence the doubling.
    static func effectiveCurvature(_ curvature: CGFloat, head: ArrowElement.Head,
                                   from start: CGPoint, to end: CGPoint) -> CGFloat {
        guard head == .curved, abs(curvature) < 0.01 else { return curvature }
        return hypot(end.x - start.x, end.y - start.y) * 0.14
    }

    /// The arrow, ready to paint.
    static func shape(from start: CGPoint, to end: CGPoint,
                      curvature: CGFloat,
                      head: ArrowElement.Head,
                      strokeWidth: CGFloat) -> Shape {
        let bow = effectiveCurvature(curvature, head: head, from: start, to: end)
        if head == .open {
            return .stroke(chevronPath(from: start, to: end, curvature: bow,
                                       strokeWidth: strokeWidth),
                           lineWidth: max(strokeWidth, 0.5))
        }
        return .fill(path(from: start, to: end, curvature: bow,
                          head: head, strokeWidth: strokeWidth))
    }

    /// The filled outline of a tapered arrow.
    static func path(from start: CGPoint, to end: CGPoint,
                     curvature: CGFloat,
                     head: ArrowElement.Head,
                     strokeWidth: CGFloat) -> CGPath {
        let bow = effectiveCurvature(curvature, head: head, from: start, to: end)
        let spine = spinePoints(from: start, to: end, curvature: bow)
        let length = polylineLength(spine)
        guard length > 0.001 else { return CGMutablePath() }

        let metrics = metrics(for: head, strokeWidth: strokeWidth, length: length)
        let junctionDistance = max(length - metrics.headLength, 0.001)

        // Walk the spine to the junction, widening **linearly** — the reference taper is straight,
        // and an eased one reads as a bulge in the middle of the shaft.
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        var travelled: CGFloat = 0
        var junction = spine[0]
        var junctionNormal = normal(of: spine, at: 0)

        for index in 0..<spine.count {
            if index > 0 { travelled += distance(spine[index - 1], spine[index]) }
            guard travelled <= junctionDistance else { break }
            let t = junctionDistance > 0 ? travelled / junctionDistance : 0
            let half = metrics.tailHalf + (metrics.neckHalf - metrics.tailHalf) * t
            let n = normal(of: spine, at: index)
            left.append(CGPoint(x: spine[index].x + n.x * half, y: spine[index].y + n.y * half))
            right.append(CGPoint(x: spine[index].x - n.x * half, y: spine[index].y - n.y * half))
            junction = spine[index]
            junctionNormal = n
        }
        if left.isEmpty {
            let n = normal(of: spine, at: 0)
            left = [CGPoint(x: start.x + n.x * metrics.tailHalf,
                            y: start.y + n.y * metrics.tailHalf)]
            right = [CGPoint(x: start.x - n.x * metrics.tailHalf,
                             y: start.y - n.y * metrics.tailHalf)]
            junction = start
            junctionNormal = n
        }

        let tip = spine[spine.count - 1]
        let direction = self.direction(of: spine)
        let headNormal = CGPoint(x: -direction.y, y: direction.x)

        func point(alongBy along: CGFloat, acrossBy across: CGFloat) -> CGPoint {
            CGPoint(x: junction.x + direction.x * along + headNormal.x * across,
                    y: junction.y + direction.y * along + headNormal.y * across)
        }

        let neckLeft = CGPoint(x: junction.x + junctionNormal.x * metrics.neckHalf,
                               y: junction.y + junctionNormal.y * metrics.neckHalf)
        let neckRight = CGPoint(x: junction.x - junctionNormal.x * metrics.neckHalf,
                                y: junction.y - junctionNormal.y * metrics.neckHalf)
        let barbLeft = point(alongBy: -metrics.barbSetback, acrossBy: metrics.headHalf)
        let barbRight = point(alongBy: -metrics.barbSetback, acrossBy: -metrics.headHalf)

        let path = CGMutablePath()
        // The tail cap: a semicircle rather than a flat end, so a thin tail doesn't look chopped.
        let tail = spine[0]
        path.move(to: left[0])
        path.addArc(tangent1End: CGPoint(x: tail.x - direction.x * metrics.tailHalf,
                                         y: tail.y - direction.y * metrics.tailHalf),
                    tangent2End: right[0], radius: metrics.tailHalf)
        path.addLine(to: right[0])
        for point in right.dropFirst() { path.addLine(to: point) }
        path.addLine(to: neckRight)
        path.addLine(to: barbRight)
        path.addLine(to: tip)
        path.addLine(to: barbLeft)
        path.addLine(to: neckLeft)
        for point in left.reversed().dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The open style: a constant-width shaft with a two-stroke chevron at the tip.
    ///
    /// Measured at head strokes `3.3 × strokeWidth` long, splayed `±30°` from the axis.
    static func chevronPath(from start: CGPoint, to end: CGPoint,
                            curvature: CGFloat, strokeWidth: CGFloat) -> CGPath {
        let spine = spinePoints(from: start, to: end, curvature: curvature)
        guard spine.count > 1 else { return CGMutablePath() }
        let w = max(strokeWidth, 0.5)
        let tip = spine[spine.count - 1]
        let direction = self.direction(of: spine)

        let path = CGMutablePath()
        path.move(to: spine[0])
        for point in spine.dropFirst() { path.addLine(to: point) }

        let barbLength = w * 3.3
        let angle = CGFloat.pi / 6      // 30°
        for sign in [CGFloat(1), -1] {
            let cosA = cos(angle), sinA = sin(angle) * sign
            // Rotate the reversed direction by ±30° to get each barb.
            let bx = -direction.x * cosA - -direction.y * sinA
            let by = -direction.x * sinA + -direction.y * cosA
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + bx * barbLength, y: tip.y + by * barbLength))
        }
        return path
    }

    // MARK: - Spine

    /// The arrow's centre line, flattened.
    static func spinePoints(from start: CGPoint, to end: CGPoint,
                            curvature: CGFloat, steps: Int = 48) -> [CGPoint] {
        guard abs(curvature) > 0.01 else {
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
        // Averaged over the last few samples: one segment of a finely sampled curve is short
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
