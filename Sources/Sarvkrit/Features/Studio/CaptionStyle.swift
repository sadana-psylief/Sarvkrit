import AppKit
import CoreGraphics
import CoreText
import Foundation

/// How captions look.
struct CaptionStyle: Codable, Equatable {
    enum Position: String, Codable, CaseIterable, Equatable { case top, centre, bottom }
    enum Highlight: String, Codable, CaseIterable, Equatable { case word, line, none }

    var fontName = "SF Pro Rounded"
    var weight: Double = 0.3
    /// Fraction of the canvas height, so a caption is the same size at 1080p and 4K.
    var sizeFraction: Double = 0.042
    var spoken = RGBAColour.white
    /// Grey rather than dimmed white, matching what the reference does — the contrast between the
    /// two is what makes the highlight legible at a glance.
    var upcoming = RGBAColour(r: 0.6, g: 0.6, b: 0.6, a: 1)
    var background = RGBAColour(r: 0, g: 0, b: 0, a: 0.78)
    var cornerRadius: Double = 14
    var paddingX: Double = 16
    var paddingY: Double = 12
    var position: Position = .bottom
    /// Distance from that edge, as a fraction of the canvas.
    var inset: Double = 0.08
    var maxWidthFraction: Double = 0.72
    var highlight: Highlight = .word

    init() {}
}

/// Drawing one caption line.
///
/// **Word-level highlighting is the thing that makes these look expensive**, and it is only
/// possible because `SFSpeechRecognizer` returns per-word timings. Spoken words are white and
/// upcoming ones grey, switching at each word's own start.
enum CaptionRenderer {

    static func draw(_ caption: Caption, spokenWords: Int, canvas: CGSize,
                     style: CaptionStyle = CaptionStyle(), in context: CGContext) {
        guard !caption.words.isEmpty, canvas.height > 0 else { return }

        let size = CGFloat(style.sizeFraction) * canvas.height
        let font = resolvedFont(style: style, size: size)
        let text = attributed(caption, spokenWords: spokenWords, style: style, font: font)

        let maxWidth = canvas.width * CGFloat(style.maxWidthFraction)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)

        let boxWidth = measured.width + CGFloat(style.paddingX) * 2
        let boxHeight = measured.height + CGFloat(style.paddingY) * 2
        let origin = boxOrigin(style: style, canvas: canvas,
                               size: CGSize(width: boxWidth, height: boxHeight))
        let box = CGRect(origin: origin, size: CGSize(width: boxWidth, height: boxHeight))

        context.saveGState()
        context.addPath(CGPath.rounded(box, cornerRadius: CGFloat(style.cornerRadius)))
        context.setFillColor(style.background.cgColor)
        context.fillPath()

        // Core Text draws bottom-up; the surrounding context is top-left, so the text block is
        // flipped back for the duration of the draw and no further.
        let textRect = box.insetBy(dx: CGFloat(style.paddingX), dy: CGFloat(style.paddingY))
        context.translateBy(x: 0, y: textRect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func attributed(_ caption: Caption, spokenWords: Int,
                                   style: CaptionStyle, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        for (index, word) in caption.words.enumerated() {
            let spoken = style.highlight == .none
                || (style.highlight == .line ? spokenWords > 0 : index < spokenWords)
            let colour = spoken ? style.spoken : style.upcoming
            let piece = NSAttributedString(
                string: index == 0 ? word.text : " " + word.text,
                attributes: [.font: font,
                             .foregroundColor: NSColor(cgColor: colour.cgColor) ?? .white,
                             .paragraphStyle: paragraph])
            result.append(piece)
        }
        return result
    }

    private static func resolvedFont(style: CaptionStyle, size: CGFloat) -> NSFont {
        let weight = NSFont.Weight(rawValue: CGFloat(style.weight))
        if style.fontName == "SF Pro Rounded" {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return NSFont(name: style.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func boxOrigin(style: CaptionStyle, canvas: CGSize, size: CGSize) -> CGPoint {
        let x = (canvas.width - size.width) / 2
        switch style.position {
        case .top:
            return CGPoint(x: x, y: canvas.height * CGFloat(style.inset))
        case .centre:
            return CGPoint(x: x, y: (canvas.height - size.height) / 2)
        case .bottom:
            return CGPoint(x: x,
                           y: canvas.height - size.height - canvas.height * CGFloat(style.inset))
        }
    }
}
