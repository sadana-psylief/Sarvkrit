import CoreGraphics
import Foundation

/// The "1920 × 1080" label.
///
/// A pure function over a size so the formatting is a test rather than something you squint at on
/// screen. Two decisions it pins: the multiplication sign rather than a lowercase x, and **pixels
/// rather than points** — points would report 960 × 540 for a Retina capture that is going to
/// produce a 1920 × 1080 file, which is the number the user actually wants.
enum DimensionReadout {

    static func text(for pixelSize: CGSize) -> String {
        "\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded()))"
    }

    /// With a scale suffix on a Retina display, so it is clear the numbers are pixels and not the
    /// points you might be measuring against in a design tool. Omitted at 1x, where it would be
    /// noise on every capture.
    static func text(for pixelSize: CGSize, scale: CGFloat) -> String {
        let base = text(for: pixelSize)
        guard scale > 1 else { return base }
        // "@2x" for whole factors, "@1.5x" for a scaled resolution — no trailing ".0".
        let formatted = scale == scale.rounded()
            ? String(Int(scale))
            : String(format: "%g", scale)
        return "\(base) @\(formatted)x"
    }
}
