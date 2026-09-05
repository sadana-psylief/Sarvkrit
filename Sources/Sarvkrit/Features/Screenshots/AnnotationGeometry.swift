import CoreGraphics
import Foundation

/// Hit-testing annotations.
///
/// **Every hittable shape is flattened to a polyline and shares one distance routine.** A curved
/// arrow becomes 16 Bézier segments, an ellipse 64, a pencil stroke already is one, a rect is
/// four. That keeps the per-tool logic to "what shape is it" and the hard part — point-to-segment
/// distance with a tolerance — in one tested function.
enum AnnotationGeometry {

    // MARK: - Distance

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        PencilSmoothing.perpendicularDistance(point, from: a, to: b)
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint],
                         closed: Bool) -> CGFloat {
        guard points.count > 1 else {
            return points.first.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .greatestFiniteMagnitude
        }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(points.count - 1) {
            best = min(best, distance(from: point, toSegment: points[index], points[index + 1]))
        }
        if closed, let first = points.first, let last = points.last {
            best = min(best, distance(from: point, toSegment: last, first))
        }
        return best
    }

    // MARK: - Flattening

    static func flatten(_ element: AnnotationElement) -> [CGPoint] {
        switch element.kind {
        case .arrow(let arrow):
            // The same threshold the renderer uses. `== 0` here against `abs > 0.01` there meant
            // a bowed arrow could be *drawn* curved and *hit-tested* as a straight chord.
            return ArrowGeometry.isStraight(arrow.curvature)
                ? [arrow.start, arrow.end]
                : quadratic(from: arrow.start, to: arrow.end, curvature: arrow.curvature, steps: 16)
        case .line(let line):
            return [line.start, line.end]
        case .rectangle(let shape):
            return corners(of: shape.rect)
        case .ellipse(let shape):
            return ellipsePoints(in: shape.rect, steps: 64)
        case .pencil(let pencil):
            return PencilSmoothing.polyline(pencil.points)
        case .text(let text):
            return corners(of: textBounds(text))
        case .highlighter(let highlight):
            return corners(of: highlight.rect)
        case .spotlight(let spotlight):
            return spotlight.isEllipse
                ? ellipsePoints(in: spotlight.rect, steps: 64)
                : corners(of: spotlight.rect)
        case .counter(let counter):
            return ellipsePoints(in: CGRect(x: counter.centre.x - counter.radius,
                                            y: counter.centre.y - counter.radius,
                                            width: counter.radius * 2,
                                            height: counter.radius * 2), steps: 32)
        case .blur(let filter), .pixelate(let filter):
            return filter.isEllipse
                ? ellipsePoints(in: filter.rect, steps: 64)
                : corners(of: filter.rect)
        case .emoji(let emoji):
            return corners(of: emoji.rect)
        case .unknown:
            return []
        }
    }

    static func quadratic(from start: CGPoint, to end: CGPoint,
                          curvature: CGFloat, steps: Int) -> [CGPoint] {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.0001)
        // Perpendicular to the chord, scaled by the stored curvature.
        let control = CGPoint(x: mid.x - dy / length * curvature,
                              y: mid.y + dx / length * curvature)
        return (0...max(1, steps)).map { step in
            let t = CGFloat(step) / CGFloat(max(1, steps))
            let mt = 1 - t
            return CGPoint(x: mt * mt * start.x + 2 * mt * t * control.x + t * t * end.x,
                           y: mt * mt * start.y + 2 * mt * t * control.y + t * t * end.y)
        }
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func ellipsePoints(in rect: CGRect, steps: Int) -> [CGPoint] {
        (0..<max(3, steps)).map { step in
            let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(max(3, steps))
            return CGPoint(x: rect.midX + cos(angle) * rect.width / 2,
                           y: rect.midY + sin(angle) * rect.height / 2)
        }
    }

    /// A rough box for a text element, good enough to hit-test and select.
    static func textBounds(_ text: TextElement) -> CGRect {
        let lines = text.string.isEmpty ? 1 : text.string.components(separatedBy: "\n").count
        let longest = text.string.components(separatedBy: "\n")
            .map(\.count).max() ?? 1
        // Mean advance per face. Monospaced is wider than the proportional faces by enough that
        // one constant would leave a code snippet's selection box ending mid-word. Kept here as a
        // number rather than measured, so this file stays free of AppKit like the rest of the
        // geometry layer.
        let advance: CGFloat = text.typeface == .monospaced ? 0.62 : 0.55
        let width = text.maxWidth ?? (CGFloat(max(longest, 1)) * text.fontSize * advance)
        let height = CGFloat(lines) * text.fontSize * 1.2
        return CGRect(x: text.origin.x - text.padding, y: text.origin.y - text.padding,
                      width: width + text.padding * 2, height: height + text.padding * 2)
    }

    // MARK: - Hit testing

    /// Whether a point hits an element.
    ///
    /// The rule that matters: **an unfilled shape hits on its outline only.** Clicking the middle
    /// of a large empty rectangle has to select whatever is underneath it, or a rectangle drawn
    /// around a region makes everything inside that region unselectable.
    static func contains(_ element: AnnotationElement, point: CGPoint,
                         tolerance: CGFloat) -> Bool {
        switch element.kind {
        case .unknown:
            // Carried, not interactive: selecting something that cannot be drawn or edited would
            // be a control that does nothing.
            return false

        case .arrow(let arrow):
            let reach = tolerance + arrow.stroke.width / 2
            if distance(from: point, toPolyline: flatten(element), closed: false) <= reach {
                return true
            }
            // The head is where people aim, and it is wider than the shaft.
            return hypot(point.x - arrow.end.x, point.y - arrow.end.y)
                <= reach + arrow.stroke.width * 2

        case .line(let line):
            return distance(from: point, toPolyline: flatten(element), closed: false)
                <= tolerance + line.stroke.width / 2

        case .pencil(let pencil):
            return distance(from: point, toPolyline: flatten(element), closed: false)
                <= tolerance + pencil.stroke.width / 2

        case .rectangle(let shape):
            if shape.fill != nil { return shape.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            return distance(from: point, toPolyline: flatten(element), closed: true)
                <= tolerance + shape.stroke.width / 2

        case .ellipse(let shape):
            if shape.fill != nil { return isInsideEllipse(point, rect: shape.rect, tolerance: tolerance) }
            return distance(from: point, toPolyline: flatten(element), closed: true)
                <= tolerance + shape.stroke.width / 2

        case .text, .highlighter, .emoji:
            return bounds(of: element).insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .counter(let counter):
            return hypot(point.x - counter.centre.x, point.y - counter.centre.y)
                <= counter.radius + tolerance

        case .spotlight(let spotlight):
            return spotlight.isEllipse
                ? isInsideEllipse(point, rect: spotlight.rect, tolerance: tolerance)
                : spotlight.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .blur(let filter), .pixelate(let filter):
            return filter.isEllipse
                ? isInsideEllipse(point, rect: filter.rect, tolerance: tolerance)
                : filter.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func isInsideEllipse(_ point: CGPoint, rect: CGRect,
                                        tolerance: CGFloat) -> Bool {
        let grown = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard grown.width > 0, grown.height > 0 else { return false }
        let nx = (point.x - grown.midX) / (grown.width / 2)
        let ny = (point.y - grown.midY) / (grown.height / 2)
        return nx * nx + ny * ny <= 1
    }

    /// Topmost element under a point, or nil.
    static func hitTest(_ document: AnnotationDocument, at point: CGPoint,
                        tolerance: CGFloat) -> AnnotationElement.ID? {
        document.drawable.reversed().first { contains($0, point: point, tolerance: tolerance) }?.id
    }

    /// The element's bounds, stroke included — a 12pt stroke sticks 6pt outside the geometry, and
    /// selection handles drawn on the bare rect would sit inside the visible mark.
    static func bounds(of element: AnnotationElement) -> CGRect {
        switch element.kind {
        case .unknown:
            return .null
        case .text(let text):
            return textBounds(text)
        case .counter(let counter):
            return CGRect(x: counter.centre.x - counter.radius, y: counter.centre.y - counter.radius,
                          width: counter.radius * 2, height: counter.radius * 2)
        default:
            let points = flatten(element)
            guard !points.isEmpty else { return .null }
            let xs = points.map(\.x), ys = points.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!,
                             width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            // `flatten` returns the arrow's *spine*, so half a stroke width covers the shaft but
            // not the head, whose barbs reach 2.25 widths to each side. Inset by that instead, or
            // the box — and the marquee that uses it — cuts the corners off the arrowhead.
            let reach: CGFloat
            if case .arrow(let arrow) = element.kind {
                reach = ArrowGeometry.metrics(for: arrow.head,
                                              strokeWidth: arrow.stroke.width,
                                              length: ArrowGeometry.polylineLength(points)).headHalf
            } else {
                reach = strokeWidth(of: element) / 2
            }
            return box.insetBy(dx: -reach, dy: -reach)
        }
    }

    static func strokeWidth(of element: AnnotationElement) -> CGFloat {
        switch element.kind {
        case .arrow(let value): return value.stroke.width
        case .line(let value): return value.stroke.width
        case .rectangle(let value), .ellipse(let value): return value.stroke.width
        case .pencil(let value): return value.stroke.width
        default: return 0
        }
    }

    /// Everything inside a marquee.
    static func elements(_ document: AnnotationDocument,
                         intersecting rect: CGRect) -> [AnnotationElement.ID] {
        document.drawable.filter { rect.intersects(bounds(of: $0)) }.map(\.id)
    }
}
