import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Blur, pixelate, and actual redaction.
///
/// **The signature is the contract: the input is always the base image.** Never the rendered
/// canvas, never a screen grab. Two overlapping blurs therefore compose order-independently, and
/// a blur can never accidentally sample an arrow drawn over the top of it.
///
/// ## The security part, which is not a style choice
///
/// - **Smooth blur** is `CIGaussianBlur`: a linear convolution, and therefore invertible up to
///   noise. Blurred 12-point text is routinely recovered. It is a *cosmetic* effect and the UI
///   calls it "Blur (smooth)" so nobody reads privacy into it.
/// - **Pixelate is also not redaction.** Depix-class attacks recover pixelated text reliably when
///   the alphabet is small — which is exactly the password, token and account-number case. A
///   minimum cell size is enforced, and it is still not called secure.
/// - **Secure blur** is defined as *carrying no information about the region beyond its mean
///   colour*: take the average, fill with it, then overlay a texture generated from the element's
///   seed rather than from the pixels. The output is a function of (mean colour, seed, geometry)
///   alone, so there is nothing left to recover.
///
/// The stake is asymmetric, which is why this is spelled out rather than left to the reader: a
/// weak blur over a password is **worse than no blur**, because the user believes they redacted it
/// and then shares the image.
enum PixelFilters {

    /// Shared, because creating a `CIContext` per render is the expensive part.
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The floor on pixelate cell size, in image pixels. Below this, small-alphabet text is
    /// recoverable.
    static func minimumCellSize(for rect: CGRect, scale: CGFloat) -> CGFloat {
        max(16 * max(scale, 1), rect.height / 6)
    }

    /// Renders one filter element, cropped to its own rect.
    ///
    /// - Parameter downscale: 1 for export; a fraction during a drag, where a quarter-resolution
    ///   blur is indistinguishable at the size it is being previewed.
    static func render(_ element: PixelFilterElement,
                       over base: CGImage,
                       downscale: CGFloat = 1) -> CGImage? {
        let rect = element.rect.integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let source = CIImage(cgImage: base)
        let extent = source.extent
        // The document is top-left and CIImage is bottom-left, so the rect has to be flipped
        // before it means anything to Core Image.
        let ciRect = CGRect(x: rect.minX, y: extent.height - rect.maxY,
                            width: rect.width, height: rect.height)

        // Secure redaction never touches Core Image — see `secure(_:element:rect:)`.
        if element.mode == .secureBlur {
            return secure(base, element: element, rect: rect)
        }

        let filtered: CIImage?
        switch element.mode {
        case .smoothBlur:
            filtered = gaussian(source, radius: element.radius * max(downscale, 0.1))
        case .pixellate:
            filtered = pixellate(source, element: element, ciRect: ciRect)
        case .secureBlur:
            filtered = nil
        }
        guard let filtered else { return nil }

        let masked = mask(filtered, over: source, rect: ciRect, isEllipse: element.isEllipse)
        return context.createCGImage(masked, from: ciRect)
    }

    // MARK: - Modes

    private static func gaussian(_ source: CIImage, radius: CGFloat) -> CIImage? {
        // **The clamp is not optional.** `CIGaussianBlur` reads outside its input extent, and
        // unclamped those samples are transparent black — which produces a dark vignette along
        // any image border the blur touches. It is the single most common way this ships broken.
        let clamped = source.clampedToExtent()
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = clamped
        filter.radius = Float(max(radius, 0.1))
        return filter.outputImage?.cropped(to: source.extent)
    }

    private static func pixellate(_ source: CIImage,
                                  element: PixelFilterElement,
                                  ciRect: CGRect) -> CIImage? {
        var generator = SeededRandom(seed: element.seed)
        let floor = minimumCellSize(for: element.rect, scale: 1)
        // ±20% jitter on the cell size and up to one cell of offset, both derived from the stored
        // seed so a reopened document renders identically instead of shimmering.
        let scale = max(element.radius, floor) * (0.8 + 0.4 * generator.nextUnit())
        let offset = CGPoint(x: ciRect.midX + (generator.nextUnit() - 0.5) * scale,
                             y: ciRect.midY + (generator.nextUnit() - 0.5) * scale)

        let filter = CIFilter.pixellate()
        filter.inputImage = source.clampedToExtent()
        filter.scale = Float(scale)
        filter.center = offset
        return filter.outputImage?.cropped(to: source.extent)
    }

    /// Mean colour plus seeded noise. Nothing in the output derives from the pixels except the
    /// average, so nothing can be recovered from it.
    ///
    /// **Built with CoreGraphics in sRGB rather than Core Image.** The average has to come back
    /// out looking like the tone it replaced, and Core Image works in a linear space: sampling an
    /// sRGB average and handing it to `CIColor` rendered the patch markedly lighter than its
    /// surroundings — a bright rectangle sitting exactly where the secret was, which is the
    /// opposite of the point. Averaging the bytes directly and filling in sRGB has no such
    /// ambiguity, and it is also simply easier to be sure about.
    private static func secure(_ base: CGImage,
                               element: PixelFilterElement,
                               rect: CGRect) -> CGImage? {
        let width = max(1, Int(rect.width)), height = max(1, Int(rect.height))
        guard let cropped = base.cropping(to: rect) else { return nil }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        guard let reader = samples.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        reader.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totals = (r: 0.0, g: 0.0, b: 0.0)
        let count = Double(width * height)
        for index in stride(from: 0, to: samples.count, by: 4) {
            totals.r += Double(samples[index])
            totals.g += Double(samples[index + 1])
            totals.b += Double(samples[index + 2])
        }
        let mean = (r: totals.r / count / 255,
                    g: totals.g / count / 255,
                    b: totals.b / count / 255)

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(srgbRed: mean.r, green: mean.g, blue: mean.b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Texture from the seed, never from the pixels, so the patch doesn't read as a flat
        // sticker while still carrying nothing. Kept faint and centred on the mean, so it cannot
        // shift the overall tone.
        var generator = SeededRandom(seed: element.seed)
        let cell = max(3, Int(element.radius / 3))
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) {
                let jitter = (generator.nextUnit() - 0.5) * 0.06
                context.setFillColor(CGColor(srgbRed: min(max(mean.r + jitter, 0), 1),
                                             green: min(max(mean.g + jitter, 0), 1),
                                             blue: min(max(mean.b + jitter, 0), 1),
                                             alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return context.makeImage()
    }

    // MARK: - Masking

    /// Composites the filtered image over the original, limited to the element's shape.
    ///
    /// Masking rather than pasting a cropped bitmap keeps an ellipse anti-aliased at its edge, and
    /// leaves room for an arbitrary shape later without changing anything here.
    private static func mask(_ filtered: CIImage, over source: CIImage,
                             rect: CGRect, isEllipse: Bool) -> CIImage {
        guard isEllipse else {
            let blend = CIFilter.sourceOverCompositing()
            blend.inputImage = filtered.cropped(to: rect)
            blend.backgroundImage = source
            return blend.outputImage ?? source
        }

        let radial = CIFilter.radialGradient()
        radial.center = CGPoint(x: rect.midX, y: rect.midY)
        radial.radius0 = Float(min(rect.width, rect.height) / 2 - 1)
        radial.radius1 = Float(min(rect.width, rect.height) / 2)
        radial.color0 = CIColor.white
        radial.color1 = CIColor.clear
        guard let gradient = radial.outputImage else { return source }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = filtered
        blend.backgroundImage = source
        blend.maskImage = gradient.cropped(to: rect)
        return blend.outputImage ?? source
    }
}

/// A tiny deterministic PRNG.
///
/// Deliberately not `SystemRandomNumberGenerator`: the jitter has to be reproducible from the
/// element's stored seed, or a document renders differently every time it is opened.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    mutating func nextUnit() -> CGFloat {
        CGFloat(Double(next() >> 11) / Double(1 << 53))
    }
}

/// Caches rendered filter patches.
///
/// On the editor's model rather than in view state, for the reason the stores record: the hosting
/// view is rebuilt whenever the window re-lays-out, so a cache in `@State` would be thrown away
/// constantly — and a Gaussian over a 5K bitmap is not something to redo per frame.
final class PixelFilterCache {
    private struct Key: Hashable {
        let rect: CGRect
        let mode: PixelFilterElement.Mode
        let radius: CGFloat
        let seed: UInt64
        let isEllipse: Bool
        let downscale: CGFloat
        let baseIdentity: ObjectIdentifier
    }

    private var entries: [Key: CGImage] = [:]

    func image(for element: PixelFilterElement, base: CGImage,
               downscale: CGFloat) -> CGImage? {
        let key = Key(rect: element.rect, mode: element.mode, radius: element.radius,
                      seed: element.seed, isEllipse: element.isEllipse, downscale: downscale,
                      baseIdentity: ObjectIdentifier(base))
        if let cached = entries[key] { return cached }
        guard let rendered = PixelFilters.render(element, over: base, downscale: downscale) else {
            return nil
        }
        entries[key] = rendered
        return rendered
    }

    func invalidate() { entries.removeAll() }
}
