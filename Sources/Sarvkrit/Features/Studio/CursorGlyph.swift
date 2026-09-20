import AppKit
import CoreGraphics
import Foundation

/// The pointers, as vector paths.
///
/// **Drawn rather than scaled from a bitmap.** A 16×16 system cursor blown up to 3× is exactly the
/// blurry mess this feature exists to avoid — and the pointer is the thing a viewer's eye follows
/// for the whole video, so it is the last place to accept softness. Paths are also data, which is
/// the same argument `CaptureBackground` makes for gradients: no assets, no @2x variants, correct
/// at every size.
///
/// Every path is drawn inside a `unitSize` box with y **down**, matching the `CGImage` convention
/// the rest of the capture stack uses.
enum CursorGlyph {

    /// The box every path is drawn in. Multiplied out at draw time.
    static let unitSize: CGFloat = 24

    /// Black fill with a white outline, which is what makes a pointer legible over both a dark
    /// terminal and a white document without either being a special case.
    static let strokeWidth: CGFloat = 1.25

    static func path(for kind: CursorKind) -> CGPath {
        switch kind {
        case .arrow, .unknown, .custom: return arrow()
        case .iBeam: return iBeam()
        case .pointingHand: return pointingHand()
        case .openHand, .closedHand: return hand(closed: kind == .closedHand)
        case .crosshair: return crosshair()
        case .resizeLeftRight: return resize(horizontal: true)
        case .resizeUpDown: return resize(horizontal: false)
        case .resizeDiagonal: return resizeDiagonal()
        case .notAllowed: return notAllowed()
        case .contextualMenu: return arrow()
        }
    }

    /// Where the click actually happened, normalised inside the unit box.
    ///
    /// An arrow's is its tip; an I-beam's is its middle. Wrong here means every click effect is
    /// offset from the thing it clicked, which reads as the app mis-clicking.
    static func hotspot(for kind: CursorKind) -> CGPoint {
        switch kind {
        case .arrow, .unknown, .custom, .contextualMenu:
            return CGPoint(x: 0, y: 0)
        case .pointingHand:
            return CGPoint(x: 0.35, y: 0.05)
        case .iBeam, .crosshair, .resizeLeftRight, .resizeUpDown, .resizeDiagonal,
             .notAllowed, .openHand, .closedHand:
            return CGPoint(x: 0.5, y: 0.5)
        }
    }

    // MARK: - Sizing

    /// How tall to draw the pointer, in canvas points.
    ///
    /// **Canvas space, not screen-layer space.** A cursor that scaled with the zoom would be
    /// comically large in a 2.5× close-up — the reference keeps it roughly constant on screen, and
    /// so do we. The quarter-power term lets it grow just enough not to look detached from a frame
    /// that got closer, and nowhere near linearly.
    ///
    /// **The user's Accessibility pointer size is deliberately not an input here**, though the plan
    /// this was built from said to divide it out. That was wrong: the recording is captured with
    /// `showsCursor = false`, so their enlarged pointer never reaches the video and there is
    /// nothing for ours to compound with. The manifest still records the setting, because it is
    /// worth *telling* somebody with a 3× pointer that the recording will not match what they see
    /// — but correcting for it silently would shrink their cursor for no reason.
    static func drawnSize(base: Double, zoom: Double) -> Double {
        base * pow(max(zoom, 1), 0.25) * Double(unitSize)
    }

    // MARK: - Rendering

    /// A glyph, its bitmap, and where the glyph sits inside it.
    ///
    /// The bitmap is larger than the glyph because a shadow needs room — and returning only the
    /// image would leave the caller scaling the padding as if it were part of the pointer, which
    /// shrinks the cursor and puts its hotspot in the wrong place.
    struct Rendered {
        let image: CGImage
        /// The glyph's own height, in image pixels.
        let glyphHeight: CGFloat
        /// Distance from the image's edge to the glyph's box.
        let inset: CGFloat
    }

    /// A ready-to-composite bitmap, cached by kind and size.
    ///
    /// Cached because a ten-minute export asks for the same handful of pointers at the same size
    /// tens of thousands of times, and rebuilding a path and a shadow for each is pure waste.
    static func rendered(for kind: CursorKind, glyphHeight: Int) -> Rendered? {
        let key = Key(kind: kind, height: glyphHeight)
        if let cached = cache.object(forKey: key) { return cached.rendered }

        let scale = CGFloat(glyphHeight) / unitSize
        let padding = ceil(6 * scale)
        let side = Int((unitSize * scale + padding * 2).rounded())

        guard let context = CGContext(data: nil, width: max(1, side), height: max(1, side),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Document space: top-left origin, y down, the same flip the annotation renderer uses.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: padding, y: padding)
        context.scaleBy(x: scale, y: scale)

        let shape = path(for: kind)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2 / scale), blur: 6 / scale,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
        context.addPath(shape)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.addPath(shape)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(strokeWidth)
        context.setLineJoin(.round)
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        let result = Rendered(image: image, glyphHeight: CGFloat(glyphHeight), inset: padding)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    /// Where the *bitmap's* top-left goes, so that the glyph's hotspot lands on `point`.
    ///
    /// The padding is subtracted here rather than by the caller, because forgetting it offsets
    /// every pointer by a few pixels — near enough to look right and wrong enough to notice.
    static func origin(for kind: CursorKind, at point: CGPoint,
                       drawnHeight: CGFloat, insetFraction: CGFloat) -> CGPoint {
        let hotspot = hotspot(for: kind)
        return CGPoint(x: point.x - hotspot.x * drawnHeight - insetFraction * drawnHeight,
                       y: point.y - hotspot.y * drawnHeight - insetFraction * drawnHeight)
    }

    private final class Key: NSObject {
        let kind: CursorKind
        let height: Int
        init(kind: CursorKind, height: Int) { self.kind = kind; self.height = height }
        override var hash: Int { kind.rawValue.hashValue ^ height }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return other.kind == kind && other.height == height
        }
    }

    private final class Box {
        let rendered: Rendered
        init(_ rendered: Rendered) { self.rendered = rendered }
    }

    private static let cache: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 48
        return cache
    }()

    // MARK: - The shapes

    /// The macOS arrow: a tip at the origin, a long left edge, a notch, and the tail.
    private static func arrow() -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 16.5 * s))
        path.addLine(to: CGPoint(x: 4.2 * s, y: 12.6 * s))
        path.addLine(to: CGPoint(x: 7.0 * s, y: 19.4 * s))
        path.addLine(to: CGPoint(x: 9.9 * s, y: 18.2 * s))
        path.addLine(to: CGPoint(x: 7.1 * s, y: 11.5 * s))
        path.addLine(to: CGPoint(x: 12.4 * s, y: 11.3 * s))
        path.closeSubpath()
        return path
    }

    private static func iBeam() -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        // Serifs top and bottom, which is what distinguishes it from a plain bar at a glance.
        path.addRect(CGRect(x: 10.6 * s, y: 4 * s, width: 1.8 * s, height: 16 * s))
        path.addRect(CGRect(x: 8 * s, y: 3.4 * s, width: 7 * s, height: 1.4 * s))
        path.addRect(CGRect(x: 8 * s, y: 19.2 * s, width: 7 * s, height: 1.4 * s))
        return path
    }

    private static func pointingHand() -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        // A raised index finger over a fist. Simplified, but the silhouette is what reads.
        path.move(to: CGPoint(x: 7.2 * s, y: 1.5 * s))
        path.addCurve(to: CGPoint(x: 10 * s, y: 1.5 * s),
                      control1: CGPoint(x: 7.2 * s, y: 0.2 * s),
                      control2: CGPoint(x: 10 * s, y: 0.2 * s))
        path.addLine(to: CGPoint(x: 10 * s, y: 10 * s))
        path.addLine(to: CGPoint(x: 13.4 * s, y: 9.4 * s))
        path.addCurve(to: CGPoint(x: 18.4 * s, y: 13.6 * s),
                      control1: CGPoint(x: 17 * s, y: 9.2 * s),
                      control2: CGPoint(x: 18.4 * s, y: 10.6 * s))
        path.addLine(to: CGPoint(x: 18.4 * s, y: 19 * s))
        path.addCurve(to: CGPoint(x: 15 * s, y: 22.4 * s),
                      control1: CGPoint(x: 18.4 * s, y: 21.2 * s),
                      control2: CGPoint(x: 17 * s, y: 22.4 * s))
        path.addLine(to: CGPoint(x: 10.4 * s, y: 22.4 * s))
        path.addCurve(to: CGPoint(x: 6.4 * s, y: 18.6 * s),
                      control1: CGPoint(x: 8 * s, y: 22.4 * s),
                      control2: CGPoint(x: 6.4 * s, y: 21 * s))
        path.closeSubpath()
        return path
    }

    private static func hand(closed: Bool) -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        let top = closed ? 8.0 : 4.0
        path.addRoundedRect(in: CGRect(x: 5 * s, y: top * s,
                                       width: 14 * s, height: (22 - top) * s),
                            cornerWidth: 4 * s, cornerHeight: 4 * s)
        if !closed {
            for finger in 0..<3 {
                path.addRoundedRect(
                    in: CGRect(x: (7.5 + Double(finger) * 3.2) * s, y: 2 * s,
                               width: 2.4 * s, height: 6 * s),
                    cornerWidth: 1.2 * s, cornerHeight: 1.2 * s)
            }
        }
        return path
    }

    private static func crosshair() -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        // A gap in the middle, so the thing being aimed at is not covered by the aim.
        path.addRect(CGRect(x: 11.2 * s, y: 1 * s, width: 1.6 * s, height: 8 * s))
        path.addRect(CGRect(x: 11.2 * s, y: 15 * s, width: 1.6 * s, height: 8 * s))
        path.addRect(CGRect(x: 1 * s, y: 11.2 * s, width: 8 * s, height: 1.6 * s))
        path.addRect(CGRect(x: 15 * s, y: 11.2 * s, width: 8 * s, height: 1.6 * s))
        return path
    }

    private static func resize(horizontal: Bool) -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        if horizontal {
            path.addRect(CGRect(x: 5 * s, y: 11 * s, width: 14 * s, height: 2 * s))
            path.move(to: CGPoint(x: 1.5 * s, y: 12 * s))
            path.addLine(to: CGPoint(x: 6.5 * s, y: 8 * s))
            path.addLine(to: CGPoint(x: 6.5 * s, y: 16 * s))
            path.closeSubpath()
            path.move(to: CGPoint(x: 22.5 * s, y: 12 * s))
            path.addLine(to: CGPoint(x: 17.5 * s, y: 8 * s))
            path.addLine(to: CGPoint(x: 17.5 * s, y: 16 * s))
            path.closeSubpath()
        } else {
            path.addRect(CGRect(x: 11 * s, y: 5 * s, width: 2 * s, height: 14 * s))
            path.move(to: CGPoint(x: 12 * s, y: 1.5 * s))
            path.addLine(to: CGPoint(x: 8 * s, y: 6.5 * s))
            path.addLine(to: CGPoint(x: 16 * s, y: 6.5 * s))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12 * s, y: 22.5 * s))
            path.addLine(to: CGPoint(x: 8 * s, y: 17.5 * s))
            path.addLine(to: CGPoint(x: 16 * s, y: 17.5 * s))
            path.closeSubpath()
        }
        return path
    }

    private static func resizeDiagonal() -> CGPath {
        var rotate = CGAffineTransform(translationX: unitSize / 2, y: unitSize / 2)
            .rotated(by: .pi / 4)
            .translatedBy(x: -unitSize / 2, y: -unitSize / 2)
        return resize(horizontal: true).copy(using: &rotate) ?? resize(horizontal: true)
    }

    private static func notAllowed() -> CGPath {
        let path = CGMutablePath()
        let s = unitSize / 24
        path.addEllipse(in: CGRect(x: 2 * s, y: 2 * s, width: 20 * s, height: 20 * s))
        path.addEllipse(in: CGRect(x: 5 * s, y: 5 * s, width: 14 * s, height: 14 * s))
        var rotate = CGAffineTransform(translationX: 12 * s, y: 12 * s)
            .rotated(by: -.pi / 4)
            .translatedBy(x: -12 * s, y: -12 * s)
        let bar = CGPath(rect: CGRect(x: 4 * s, y: 10.8 * s, width: 16 * s, height: 2.4 * s),
                         transform: &rotate)
        path.addPath(bar)
        return path
    }
}
