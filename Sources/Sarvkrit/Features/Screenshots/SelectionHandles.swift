import CoreGraphics
import Foundation

/// The grab points around a selected annotation.
///
/// **Handles live in view space, not image space.** A handle sized in image pixels would be a
/// 24pt target at 4× zoom and a 1.5pt one at 25% — the physical size is what the hand cares
/// about, so the caller converts the bounds to view coordinates first and these work there.
enum SelectionHandles {

    enum Handle: Hashable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        /// Endpoint handles, for arrows and lines.
        case start, end
        /// The bow of a curved arrow.
        case curve

        /// The corner that stays put while this one is dragged.
        var opposite: Handle? {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomRight: return .topLeft
            case .bottomLeft: return .topRight
            case .top: return .bottom
            case .bottom: return .top
            case .left: return .right
            case .right: return .left
            default: return nil
            }
        }

        var isCorner: Bool {
            [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self)
        }
    }

    static let defaultSize: CGFloat = 9
    /// Never let a resize collapse a shape to nothing — a zero-size element cannot be grabbed
    /// again, so it is only recoverable by undo.
    static let minimumSide: CGFloat = 8

    /// The eight box handles.
    /// The three handles an arrow gets: its two ends and the bow in the middle.
    ///
    /// **An arrow is not a box.** It was given the eight handles of its bounding rectangle, which
    /// could stretch it but could never move one end without moving the other, and offered no way
    /// at all to bend it — `curvature` was stored, encoded, rendered and hit-tested, and nothing
    /// in the app ever wrote to it.
    ///
    /// The bow sits at the curve's midpoint, which is *half* the control offset: a quadratic
    /// reaches half of it at t = 0.5. `curvature(forBowAt:)` is the exact inverse, so dragging the
    /// handle onto the chord gives zero and the arrow comes back straight.
    static func arrowHandles(start: CGPoint, end: CGPoint, curvature: CGFloat,
                             size: CGFloat = defaultSize) -> [Handle: CGRect] {
        let half = size / 2
        func rect(_ point: CGPoint) -> CGRect {
            CGRect(x: point.x - half, y: point.y - half, width: size, height: size)
        }
        return [.start: rect(start),
                .end: rect(end),
                .curve: rect(bowPoint(start: start, end: end, curvature: curvature))]
    }

    /// Where the bow handle sits for a given curvature.
    static func bowPoint(start: CGPoint, end: CGPoint, curvature: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let normal = chordNormal(start: start, end: end)
        return CGPoint(x: mid.x + normal.dx * curvature / 2,
                       y: mid.y + normal.dy * curvature / 2)
    }

    /// The curvature that would put the bow handle at `point`. The inverse of `bowPoint`.
    static func curvature(forBowAt point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let normal = chordNormal(start: start, end: end)
        // Projected onto the normal, so dragging along the chord does nothing and only the
        // sideways component bends the arrow.
        return 2 * ((point.x - mid.x) * normal.dx + (point.y - mid.y) * normal.dy)
    }

    /// Unit normal to the chord. Matches `AnnotationGeometry.quadratic`, which is what actually
    /// draws the curve — the two disagreeing would put the handle somewhere the arrow is not.
    private static func chordNormal(start: CGPoint, end: CGPoint) -> CGVector {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    static func rects(for bounds: CGRect, size: CGFloat = defaultSize) -> [Handle: CGRect] {
        let half = size / 2
        func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - half, y: y - half, width: size, height: size)
        }
        return [
            .topLeft: rect(bounds.minX, bounds.minY),
            .top: rect(bounds.midX, bounds.minY),
            .topRight: rect(bounds.maxX, bounds.minY),
            .right: rect(bounds.maxX, bounds.midY),
            .bottomRight: rect(bounds.maxX, bounds.maxY),
            .bottom: rect(bounds.midX, bounds.maxY),
            .bottomLeft: rect(bounds.minX, bounds.maxY),
            .left: rect(bounds.minX, bounds.midY),
        ]
    }

    static func handle(at point: CGPoint, bounds: CGRect,
                       size: CGFloat = defaultSize) -> Handle? {
        // Corners first: at a small selection the corner and edge handles overlap, and the corner
        // is the one that resizes both axes, which is what the user is reaching for.
        let all = rects(for: bounds, size: size)
        if let corner = all.first(where: { $0.key.isCorner && $0.value.contains(point) }) {
            return corner.key
        }
        return all.first { $0.value.contains(point) }?.key
    }

    /// Applies a drag to one handle, keeping the opposite corner fixed.
    ///
    /// Dragging *through* the opposite edge flips the rect rather than collapsing it, which is
    /// what every drawing tool does and what the hand expects.
    static func resize(_ bounds: CGRect, handle: Handle, to point: CGPoint,
                       constrainAspect: Bool,
                       minimumSide: CGFloat = minimumSide) -> CGRect {
        var minX = bounds.minX, maxX = bounds.maxX
        var minY = bounds.minY, maxY = bounds.maxY

        switch handle {
        case .topLeft:     minX = point.x; minY = point.y
        case .top:         minY = point.y
        case .topRight:    maxX = point.x; minY = point.y
        case .right:       maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom:      maxY = point.y
        case .bottomLeft:  minX = point.x; maxY = point.y
        case .left:        minX = point.x
        // Handled by the arrow path in the canvas, which knows the element's endpoints; a
        // bounding box cannot express "move this end" or "bend it here".
        case .start, .end, .curve: return bounds
        }

        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))

        if constrainAspect, bounds.height > 0 {
            let aspect = bounds.width / bounds.height
            let side = max(rect.width, rect.height * aspect)
            let anchoredLeft = handle == .topRight || handle == .bottomRight || handle == .right
            let anchoredTop = handle == .bottomLeft || handle == .bottomRight || handle == .bottom
            rect = CGRect(
                x: anchoredLeft ? bounds.minX : bounds.maxX - side,
                y: anchoredTop ? bounds.minY : bounds.maxY - side / aspect,
                width: side, height: side / aspect)
        }

        // Clamp last, and grow from the anchored edge, so hitting the floor doesn't move the
        // corner the user is holding still.
        if rect.width < minimumSide {
            let anchoredLeft = handle == .topRight || handle == .bottomRight || handle == .right
            rect = CGRect(x: anchoredLeft ? rect.minX : rect.maxX - minimumSide, y: rect.minY,
                          width: minimumSide, height: rect.height)
        }
        if rect.height < minimumSide {
            let anchoredTop = handle == .bottomLeft || handle == .bottomRight || handle == .bottom
            rect = CGRect(x: rect.minX, y: anchoredTop ? rect.minY : rect.maxY - minimumSide,
                          width: rect.width, height: minimumSide)
        }
        return rect
    }
}

/// Snapping the crop rect to the edges that matter.
enum CropSnapping {

    /// Image edges and midlines. Content edges can be added later without changing callers.
    static func defaultGuides(imageSize: CGSize) -> (x: [CGFloat], y: [CGFloat]) {
        (x: [0, imageSize.width / 2, imageSize.width],
         y: [0, imageSize.height / 2, imageSize.height])
    }

    /// Pulls each edge of `rect` to the nearest guide within `threshold`.
    ///
    /// Nearest wins where two guides are both in range, and a guide beyond the threshold is
    /// ignored entirely — otherwise the rect would jump across the image to the only guide there is.
    static func snap(_ rect: CGRect, xGuides: [CGFloat], yGuides: [CGFloat],
                     threshold: CGFloat) -> CGRect {
        func pull(_ value: CGFloat, to guides: [CGFloat]) -> CGFloat {
            guard let nearest = guides.min(by: { abs($0 - value) < abs($1 - value) }),
                  abs(nearest - value) <= threshold else { return value }
            return nearest
        }
        let minX = pull(rect.minX, to: xGuides)
        let maxX = pull(rect.maxX, to: xGuides)
        let minY = pull(rect.minY, to: yGuides)
        let maxY = pull(rect.maxY, to: yGuides)
        // Snapping both edges to the same guide would collapse the rect; keep the original then.
        guard maxX > minX, maxY > minY else { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Reshapes a rect to an aspect ratio, keeping `anchor` fixed, then clamps it inside the image
    /// **without changing the ratio** — clamping naively would silently letterbox the result.
    static func constrain(_ rect: CGRect, to ratio: AspectRatio, anchor: CGPoint,
                          originalSize: CGSize, imageSize: CGSize) -> CGRect {
        guard let target = ratio.value(originalSize: originalSize), target > 0 else { return rect }

        var width = rect.width
        var height = width / target
        if height > rect.height * 2 { height = rect.height; width = height * target }

        // Shrink uniformly until it fits, rather than trimming one axis.
        let scale = min(1, min(imageSize.width / max(width, 0.0001),
                               imageSize.height / max(height, 0.0001)))
        width *= scale
        height *= scale

        var origin = CGPoint(x: anchor.x <= rect.midX ? anchor.x : anchor.x - width,
                             y: anchor.y <= rect.midY ? anchor.y : anchor.y - height)
        origin.x = min(max(origin.x, 0), max(0, imageSize.width - width))
        origin.y = min(max(origin.y, 0), max(0, imageSize.height - height))
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }
}
