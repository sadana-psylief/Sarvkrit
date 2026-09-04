import CoreGraphics
import Foundation

/// The screenshot itself, blurred past recognition, as its own backdrop.
///
/// **Why downscale-and-back rather than a Gaussian.** The blur wanted here is enormous — six per
/// cent of the shorter side, so eighty pixels on a 4K capture — and a separable Gaussian at that
/// radius costs more per frame than the whole rest of the canvas draw. Resampling to a few dozen
/// pixels and drawing back up with high-quality interpolation is the same picture for this
/// purpose, in about a millisecond, and it stays in CoreGraphics device RGB throughout. Core
/// Image would drag in the sRGB/CIColor lightness shift `MeshRenderer` documents avoiding, for a
/// result nobody could tell apart at this radius.
///
/// The radius is a *fraction* of the shorter side rather than a pixel count, so a 4K capture and a
/// 400-pixel one blur to the same look instead of the same arithmetic.
enum BlurredBackdrop {

    private static let cache = NSCache<Key, CGImage>()

    private final class Key: NSObject {
        let source: ObjectIdentifier
        let width: Int, height: Int
        let amount: Double, tint: Double

        init(source: CGImage, size: CGSize, blur: CaptureBackground.Blur) {
            self.source = ObjectIdentifier(source)
            self.width = Int(size.width.rounded())
            self.height = Int(size.height.rounded())
            self.amount = blur.amount
            self.tint = blur.tint
            super.init()
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(source); hasher.combine(width); hasher.combine(height)
            hasher.combine(amount); hasher.combine(tint)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return source == other.source && width == other.width && height == other.height
                && amount == other.amount && tint == other.tint
        }
    }

    /// The backdrop for `image` at `size`, aspect-filled, blurred and tinted.
    static func render(_ image: CGImage, size: CGSize,
                       blur: CaptureBackground.Blur) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let key = Key(source: image, size: size, blur: blur)
        if let cached = cache.object(forKey: key) { return cached }
        guard let rendered = draw(image, size: size, blur: blur) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    private static func draw(_ image: CGImage, size: CGSize,
                             blur: CaptureBackground.Blur) -> CGImage? {
        // How small to go. One pixel of the small image becomes one blur radius of the large one,
        // which is what makes `amount` mean the same thing at every capture size. Floored at 2:
        // a one-pixel intermediate is a flat average, and the backdrop stops responding to the
        // picture at all.
        let amount = min(max(blur.amount, 0.005), 0.5)
        let small = CGSize(width: max((size.width * amount).rounded(), 2),
                           height: max((size.height * amount).rounded(), 2))

        guard let downscaled = context(small),
              let full = context(size) else { return nil }

        // Aspect-fill into the small context, so the backdrop covers the canvas rather than
        // letterboxing it — a blurred backdrop with bars is worse than no backdrop.
        downscaled.interpolationQuality = .high
        downscaled.drawFlipped(image, in: fill(CGSize(width: image.width, height: image.height),
                                               into: small))
        guard let reduced = downscaled.makeImage() else { return nil }

        full.interpolationQuality = .high
        full.drawFlipped(reduced, in: CGRect(origin: .zero, size: size))

        // Tint: toward white above zero, toward black below. The reference offers one light
        // backdrop and two dark ones, and this is the axis between them.
        if blur.tint != 0 {
            let level: CGFloat = blur.tint > 0 ? 1 : 0
            full.setFillColor(CGColor(srgbRed: level, green: level, blue: level,
                                      alpha: min(abs(blur.tint), 1)))
            full.fill(CGRect(origin: .zero, size: size))
        }
        return full.makeImage()
    }

    private static func context(_ size: CGSize) -> CGContext? {
        let context = CGContext(data: nil,
                                width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // Top-left origin, matching every other surface in this feature.
        context?.translateBy(x: 0, y: size.height.rounded())
        context?.scaleBy(x: 1, y: -1)
        return context
    }

    /// `source` scaled to cover `target`, centred — the rect to draw it in.
    static func fill(_ source: CGSize, into target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = max(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (target.width - size.width) / 2,
                      y: (target.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
