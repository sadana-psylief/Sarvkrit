import AppKit
import CoreGraphics
import Foundation

/// Drawing a document.
///
/// **One code path for the canvas and the export**, which is why this takes a `CGContext` rather
/// than owning one: what you see while editing is produced by the same function that produces the
/// file, so there is nothing that can drift between them.
enum AnnotationRenderer {

    enum Quality {
        /// During a drag: expensive filters render at reduced resolution.
        case interactive
        case export
    }

    /// Draws the base image and every element into an already-positioned context.
    ///
    /// The context is expected to be in **image pixel space with a top-left origin**, matching the
    /// document. Callers flip once, outside.
    static func draw(_ document: AnnotationDocument,
                     base: CGImage,
                     in context: CGContext,
                     filterCache: PixelFilterCache? = nil,
                     quality: Quality = .interactive) {
        let bounds = CGRect(origin: .zero, size: document.imageSize)
        // Flipped: the context is in top-left document space, and `draw(_:in:)` would otherwise
        // place the picture bottom-up. See `CGContext.drawFlipped`.
        context.drawFlipped(base, in: bounds)

        for element in document.drawable {
            draw(element, base: base, in: context, filterCache: filterCache, quality: quality)
        }
    }

    /// Where the screenshot sits inside its background, and how big the whole composition is.
    ///
    /// One function so the canvas and the export cannot disagree about it — the editor showing a
    /// different layout from the file it produces is worse than showing no background at all.
    static func composition(for document: AnnotationDocument)
        -> (canvasSize: CGSize, imageRect: CGRect) {
        let content = document.contentRect
        guard let background = document.background else {
            return (content.size, CGRect(origin: .zero, size: content.size))
        }
        let layout = BackgroundLayout.compute(imageSize: content.size, style: background)
        return (canvasSize: layout.canvas, imageRect: layout.imageRect)
    }

    /// Draws the background, if there is one, into a top-left context of `canvasSize`.
    static func drawBackground(_ document: AnnotationDocument,
                               canvasSize: CGSize,
                               imageRect: CGRect,
                               in context: CGContext) {
        guard let style = document.background else { return }
        BackgroundCompositor.drawSurround(style: style,
                                          canvas: CGRect(origin: .zero, size: canvasSize),
                                          imageRect: imageRect,
                                          in: context)
    }

    /// Flattens to a new image, honouring the crop.
    static func flatten(_ document: AnnotationDocument, base: CGImage) -> CGImage? {
        let size = document.imageSize
        guard size.width >= 1, size.height >= 1 else { return nil }
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // CGContext is bottom-left; the document is top-left. Flip once here so every element
        // draws in document coordinates.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        draw(document, base: base, in: context, quality: .export)

        guard let full = context.makeImage() else { return nil }
        guard let crop = document.cropRect else { return full }
        return full.cropping(to: crop.integral) ?? full
    }

    // MARK: - Elements

    static func draw(_ element: AnnotationElement,
                     base: CGImage,
                     in context: CGContext,
                     filterCache: PixelFilterCache?,
                     quality: Quality) {
        context.saveGState()
        defer { context.restoreGState() }

        switch element.kind {
        case .unknown:
            // Carried, not rendered. Drawing a placeholder would be worse than nothing: it would
            // appear in the exported file.
            break

        case .arrow(let arrow):
            drawArrow(arrow, in: context)

        case .line(let line):
            context.setStrokeColor(line.stroke.colour.cgColor)
            context.setLineWidth(line.stroke.width)
            context.setLineCap(.round)
            context.move(to: line.start)
            context.addLine(to: line.end)
            context.strokePath()

        case .rectangle(let shape):
            let path = CGPath(roundedRect: shape.rect,
                              cornerWidth: shape.cornerRadius, cornerHeight: shape.cornerRadius,
                              transform: nil)
            if let fill = shape.fill {
                context.setFillColor(fill.cgColor)
                context.addPath(path)
                context.fillPath()
            }
            context.setStrokeColor(shape.stroke.colour.cgColor)
            context.setLineWidth(shape.stroke.width)
            context.addPath(path)
            context.strokePath()

        case .ellipse(let shape):
            if let fill = shape.fill {
                context.setFillColor(fill.cgColor)
                context.fillEllipse(in: shape.rect)
            }
            context.setStrokeColor(shape.stroke.colour.cgColor)
            context.setLineWidth(shape.stroke.width)
            context.strokeEllipse(in: shape.rect)

        case .pencil(let pencil):
            drawPencil(pencil, in: context)

        case .highlighter(let highlight):
            // Multiply, so it reads like a marker over text rather than a coloured box on top.
            context.setBlendMode(.multiply)
            context.setFillColor(highlight.colour.cgColor)
            context.fill(highlight.rect)

        case .text(let text):
            drawText(text, in: context)

        case .counter(let counter):
            drawCounter(counter, in: context)

        case .emoji(let emoji):
            drawEmoji(emoji, in: context)

        case .spotlight(let spotlight):
            drawSpotlight(spotlight, imageSize: CGSize(width: base.width, height: base.height),
                          in: context)

        case .blur(let filter), .pixelate(let filter):
            let scale: CGFloat = quality == .interactive ? 0.25 : 1
            if let rendered = filterCache?.image(for: filter, base: base, downscale: scale)
                ?? PixelFilters.render(filter, over: base, downscale: scale) {
                context.draw(rendered, in: filter.rect)
            }
        }
    }

    private static func drawArrow(_ arrow: ArrowElement, in context: CGContext) {
        // A filled outline for the tapered styles and a stroked chevron for the open one — see
        // `ArrowGeometry`, which is built to measurements rather than to taste.
        switch ArrowGeometry.shape(from: arrow.start, to: arrow.end,
                                   curvature: arrow.curvature,
                                   head: arrow.head,
                                   strokeWidth: arrow.stroke.width) {
        case .fill(let path):
            context.setFillColor(arrow.stroke.colour.cgColor)
            context.addPath(path)
            context.fillPath()
        case .stroke(let path, let lineWidth):
            context.setStrokeColor(arrow.stroke.colour.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        }
    }

    private static func drawPencil(_ pencil: PencilElement, in context: CGContext) {
        guard pencil.points.count > 1 else {
            // A single tap is a dot, not nothing — otherwise clicking with the pencil appears to
            // do nothing at all.
            guard let point = pencil.points.first else { return }
            context.setFillColor(pencil.stroke.colour.cgColor)
            context.fillEllipse(in: CGRect(x: point.x - pencil.stroke.width / 2,
                                           y: point.y - pencil.stroke.width / 2,
                                           width: pencil.stroke.width,
                                           height: pencil.stroke.width))
            return
        }
        context.setStrokeColor(pencil.stroke.colour.cgColor)
        context.setLineWidth(pencil.stroke.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let curves = PencilSmoothing.catmullRomBeziers(pencil.points)
        context.move(to: curves[0].from)
        for curve in curves {
            context.addCurve(to: curve.to, control1: curve.control1, control2: curve.control2)
        }
        context.strokePath()
    }

    private static func drawText(_ text: TextElement, in context: CGContext) {
        let font = NSFont(name: text.fontName, size: text.fontSize)
            ?? NSFont.systemFont(ofSize: text.fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: text.colour.cgColor) ?? .red,
        ]
        let string = NSAttributedString(string: text.string, attributes: attributes)
        let size = string.size()

        if let background = text.background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: text.origin.x - text.padding, y: text.origin.y - text.padding,
                                width: size.width + text.padding * 2,
                                height: size.height + text.padding * 2))
        }

        // The context is flipped into document space, so text drawn through AppKit would come out
        // upside down. Flip back for the glyphs alone.
        context.saveGState()
        context.translateBy(x: 0, y: text.origin.y * 2 + size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: CGPoint(x: text.origin.x, y: text.origin.y))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func drawCounter(_ counter: CounterElement, in context: CGContext) {
        let rect = CGRect(x: counter.centre.x - counter.radius,
                          y: counter.centre.y - counter.radius,
                          width: counter.radius * 2, height: counter.radius * 2)
        context.setFillColor(counter.fill.cgColor)
        context.fillEllipse(in: rect)

        let font = NSFont.systemFont(ofSize: counter.radius * 1.1, weight: .semibold)
        let string = NSAttributedString(string: "\(counter.number)", attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: counter.textColour.cgColor) ?? .white,
        ])
        let size = string.size()
        let origin = CGPoint(x: counter.centre.x - size.width / 2,
                             y: counter.centre.y - size.height / 2)

        context.saveGState()
        context.translateBy(x: 0, y: origin.y * 2 + size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func drawEmoji(_ emoji: EmojiElement, in context: CGContext) {
        let font = NSFont.systemFont(ofSize: emoji.rect.height)
        let string = NSAttributedString(string: emoji.emoji, attributes: [.font: font])
        context.saveGState()
        context.translateBy(x: 0, y: emoji.rect.minY * 2 + emoji.rect.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: emoji.rect.origin)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func drawSpotlight(_ spotlight: SpotlightElement,
                                      imageSize: CGSize, in context: CGContext) {
        // Dim everything *except* the spotlit region: one fill with the even-odd rule rather than
        // four rectangles, which would leave hairline seams where they meet.
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: imageSize))
        if spotlight.isEllipse {
            path.addEllipse(in: spotlight.rect)
        } else {
            path.addRoundedRect(in: spotlight.rect,
                                cornerWidth: spotlight.cornerRadius,
                                cornerHeight: spotlight.cornerRadius)
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: spotlight.dimming))
        context.addPath(path)
        context.fillPath(using: .evenOdd)
    }
}

extension RGBAColour {
    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
