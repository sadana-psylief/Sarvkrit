import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Drawing a string into a frame, with wrapping.
///
/// **Three places in this app each rolled their own attributed-string pipeline and none was
/// shareable**: `CaptionRenderer` (Core Text, wraps properly), `AnnotationRenderer.drawText`
/// (private, in another feature, single-line only) and `KeystrokeRenderer`'s pills. This is the one
/// that new text goes through.
///
/// Captions and keystroke pills are deliberately *not* moved onto it yet: both have snapshot tests
/// and re-laying them out would move pixels for no user-visible gain. Worth doing, separately.
enum TextLayer {

    struct Style {
        var font: NSFont
        var colour: RGBAColour
        var background: RGBAColour?
        var padding: CGFloat = 12
        var cornerRadius: CGFloat = 10
        /// A halo behind the glyphs, for text over a photograph that cannot wear a box.
        var haloColour: RGBAColour?
        var opacity: Double = 1
    }

    /// The box `draw` would fill, without drawing it — for hit-testing what is on screen.
    static func box(for string: String, centredOn centre: CGPoint, maxWidth: CGFloat,
                    style: Style) -> CGRect {
        guard !string.isEmpty, maxWidth > 1 else { return .zero }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: string, attributes: [
            .font: style.font,
            .paragraphStyle: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        return CGRect(x: centre.x - (measured.width + style.padding * 2) / 2,
                      y: centre.y - (measured.height + style.padding * 2) / 2,
                      width: measured.width + style.padding * 2,
                      height: measured.height + style.padding * 2)
    }

    /// Draws `string` centred horizontally on `centre`, wrapped to `maxWidth`.
    ///
    /// - Returns: the box it filled, so a caller can hit-test what it drew.
    @discardableResult
    static func draw(_ string: String, centredOn centre: CGPoint, maxWidth: CGFloat,
                     style: Style, in context: CGContext) -> CGRect {
        guard !string.isEmpty, maxWidth > 1, style.opacity > 0.001 else { return .zero }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: NSColor(cgColor: style.colour.cgColor) ?? .white,
            .paragraphStyle: paragraph,
        ]
        if let halo = style.haloColour {
            // Stroke *and* fill: a negative width means "outline behind the glyphs", which is the
            // only way to get a halo without drawing the string twice.
            attributes[.strokeColor] = NSColor(cgColor: halo.cgColor) ?? .black
            attributes[.strokeWidth] = -6.0
        }

        let text = NSAttributedString(string: string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)

        let box = CGRect(x: centre.x - (measured.width + style.padding * 2) / 2,
                         y: centre.y - (measured.height + style.padding * 2) / 2,
                         width: measured.width + style.padding * 2,
                         height: measured.height + style.padding * 2)

        context.saveGState()
        context.setAlpha(CGFloat(style.opacity))
        if let background = style.background {
            context.addPath(CGPath.rounded(box, cornerRadius: style.cornerRadius))
            context.setFillColor(background.cgColor)
            context.fillPath()
        }

        // Core Text draws bottom-up and the surrounding context is top-left, so the block is
        // flipped back for the duration of the draw and no further — the same dance
        // `CaptionRenderer` does, for the same reason.
        let textRect = box.insetBy(dx: style.padding, dy: style.padding)
        context.translateBy(x: 0, y: textRect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return box
    }
}
