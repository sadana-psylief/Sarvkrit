import CoreGraphics
import Foundation

/// Paints a `MeshSpec` — a grid of colours blended in two directions.
///
/// **CoreGraphics, deliberately, not Core Image.** `PixelFilters` records what happens otherwise:
/// Core Image works in a linear space, and an sRGB colour handed through `CIColor` came back
/// "markedly lighter than its surroundings". Backgrounds sit next to each other in a swatch grid
/// where a lightness shift is immediately obvious, and the rest of the compositor draws through
/// `CGGradient` in device RGB. Two colour pipelines would not agree.
///
/// It also sidesteps SwiftUI's `MeshGradient`, which needs macOS 15 where this app targets 14.4 —
/// and which, being a `View`, would have to be rasterised through `ImageRenderer` as a second
/// renderer, forfeiting the one-function property the swatch depends on.
enum MeshRenderer {

    /// Smoothstep. Plain linear interpolation between control points looks boxy — you can see the
    /// grid — because the gradient of the colour is discontinuous at every control line. Easing
    /// each axis makes the first derivative continuous, which is what reads as organic.
    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// The colour at a normalised position. Pure, and the whole of the maths.
    ///
    /// - Parameters:
    ///   - x: 0…1 across the grid, left to right.
    ///   - y: 0…1 down the grid.
    static func colour(_ spec: MeshSpec, x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
        guard spec.isWellFormed else { return (1, 1, 1) }
        let fx = min(max(x, 0), 1) * Double(spec.columns - 1)
        let fy = min(max(y, 0), 1) * Double(spec.rows - 1)
        // Clamped one short of the last index so the far edge lands exactly on the last control
        // colour rather than one cell past it.
        let c0 = min(Int(fx), spec.columns - 2)
        let r0 = min(Int(fy), spec.rows - 2)
        let tx = ease(fx - Double(c0))
        let ty = ease(fy - Double(r0))

        let topLeft = spec.colour(column: c0, row: r0)
        let topRight = spec.colour(column: c0 + 1, row: r0)
        let bottomLeft = spec.colour(column: c0, row: r0 + 1)
        let bottomRight = spec.colour(column: c0 + 1, row: r0 + 1)

        /// Bilinear across the cell, with both axes already eased.
        func blend(_ topLeft: Double, _ topRight: Double,
                   _ bottomLeft: Double, _ bottomRight: Double) -> Double {
            let top = topLeft + (topRight - topLeft) * tx
            let bottom = bottomLeft + (bottomRight - bottomLeft) * tx
            return top + (bottom - top) * ty
        }
        return (blend(topLeft.r, topRight.r, bottomLeft.r, bottomRight.r),
                blend(topLeft.g, topRight.g, bottomLeft.g, bottomRight.g),
                blend(topLeft.b, topRight.b, bottomLeft.b, bottomRight.b))
    }

    /// A 4×4 ordered dither, which is what stops a large background banding.
    ///
    /// **Measured, not assumed.** A smooth gradient in 8-bit has only about 120 distinct levels
    /// across a wide span — 122 colours in 125 hard steps over 380 pixels, which stretched to a
    /// 3024-pixel export is 25-pixel bands. Adding ±half a level of ordered noise before
    /// quantising took the same span to 296 transitions, breaking the steps into grain.
    ///
    /// It has to be applied at the size the pixels will actually be. Dithering a small buffer and
    /// scaling it up averages the noise away and the bands come straight back, which is the whole
    /// reason this renders at full size and caches rather than rendering small and stretching.
    private static let bayer: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { $0 / 16.0 - 0.5 }

    /// Beyond this the memory is not worth the extra smoothness; CoreGraphics scales the rest.
    private static let pixelBudget = 4_000_000

    static func image(_ spec: MeshSpec, width: Int, height: Int) -> CGImage? {
        guard spec.isWellFormed, width > 0, height > 0 else { return nil }

        var w = width, h = height
        if w * h > pixelBudget {
            let scale = (Double(pixelBudget) / Double(w * h)).squareRoot()
            w = max(1, Int(Double(w) * scale))
            h = max(1, Int(Double(h) * scale))
        }

        if let cached = cache.object(forKey: Key(spec: spec, width: w, height: h)) {
            return cached.image
        }

        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let ny = h > 1 ? Double(y) / Double(h - 1) : 0
            for x in 0..<w {
                let nx = w > 1 ? Double(x) / Double(w - 1) : 0
                let (r, g, b) = colour(spec, x: nx, y: ny)
                let noise = bayer[(y % 4) * 4 + (x % 4)]
                let offset = (y * w + x) * 4
                bytes[offset] = quantise(r, noise)
                bytes[offset + 1] = quantise(g, noise)
                bytes[offset + 2] = quantise(b, noise)
                bytes[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(
                                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { return nil }

        cache.setObject(Box(image: image), forKey: Key(spec: spec, width: w, height: h))
        return image
    }

    private static func quantise(_ value: Double, _ noise: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255 + noise).rounded())))
    }

    // MARK: - Cache

    /// Rendering happens at full size so the dither survives, which is too much work to repeat on
    /// every redraw of the live canvas — and the canvas asks for the same size over and over.
    private final class Box: NSObject {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }

    private final class Key: NSObject {
        let spec: MeshSpec
        let width: Int
        let height: Int
        init(spec: MeshSpec, width: Int, height: Int) {
            self.spec = spec; self.width = width; self.height = height
        }
        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(width); hasher.combine(height)
            hasher.combine(spec.columns); hasher.combine(spec.rows)
            for colour in spec.colours {
                hasher.combine(colour.r); hasher.combine(colour.g); hasher.combine(colour.b)
            }
            return hasher.finalize()
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return width == other.width && height == other.height && spec == other.spec
        }
    }

    private static let cache: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 24
        return cache
    }()
}
