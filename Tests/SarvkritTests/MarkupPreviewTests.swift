import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Renders the marks to PNGs so their *appearance* can be checked, not just their numbers.
///
/// The geometry suites pin proportions and the coding suites pin round-trips, but neither can see
/// that an arrow reads as an arrow or that a counter's gradient is subtle rather than glossy. This
/// writes a sheet to look at, and asserts only the few things a picture can be wrong about
/// silently — that every mark actually painted, and that the arrow it painted measures what
/// `ArrowGeometry` claims.
///
/// Writes only when `SARVKRIT_PREVIEW_DIR` is set, following the other snapshot suites here:
///
///     SARVKRIT_PREVIEW_DIR=/tmp/sarvkrit-preview make test
final class MarkupPreviewTests: XCTestCase {

    private func white(_ size: CGSize) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    private func write(_ image: CGImage, _ name: String) throws {
        guard let directory = PreviewDirectory.path else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    /// Every arrow style, straight and bowed, at three thicknesses.
    func testTheArrowSheetRenders() throws {
        let size = CGSize(width: 900, height: 620)
        var document = AnnotationDocument(imageSize: size)
        var y: CGFloat = 60
        for head in ArrowElement.Head.allCases {
            for (index, width) in [CGFloat(6), 12, 22].enumerated() {
                let x = 60 + CGFloat(index) * 280
                document.elements.append(AnnotationElement(kind: .arrow(ArrowElement(
                    start: CGPoint(x: x, y: y + 40), end: CGPoint(x: x + 220, y: y),
                    curvature: head == .curved
                        ? ArrowGeometry.defaultCurvature(from: CGPoint(x: x, y: y + 40),
                                                         to: CGPoint(x: x + 220, y: y))
                        : 0,
                    head: head,
                    stroke: StrokeStyle(colour: .red, width: width)))))
            }
            y += 150
        }
        let image = try XCTUnwrap(AnnotationRenderer.flatten(document, base: white(size)))
        try write(image, "markup-arrows")
        XCTAssertEqual(image.width, Int(size.width))
    }

    /// The whole palette, as counters and as arrows, so the shades can be judged side by side.
    func testThePaletteSheetRenders() throws {
        let size = CGSize(width: 900, height: 320)
        var document = AnnotationDocument(imageSize: size)
        for (index, colour) in AnnotationPalette.colours.enumerated() {
            let x = 60 + CGFloat(index) * 76
            document.elements.append(AnnotationElement(kind: .counter(CounterElement(
                centre: CGPoint(x: x, y: 80), radius: 26,
                number: index + 1, fill: colour,
                textColour: colour.readableForeground))))
            document.elements.append(AnnotationElement(kind: .arrow(ArrowElement(
                start: CGPoint(x: x - 18, y: 260), end: CGPoint(x: x + 18, y: 170),
                head: .filled, stroke: StrokeStyle(colour: colour, width: 12)))))
        }
        let image = try XCTUnwrap(AnnotationRenderer.flatten(document, base: white(size)))
        try write(image, "markup-palette")
        XCTAssertEqual(image.width, Int(size.width))
    }

    /// A filled mark is lit from the top, and only just.
    ///
    /// Two failure modes, and the gap between them is narrow: no gradient at all reads as a flat
    /// sticker, and too much reads as a glossy 2008 button. So this pins both ends — the top must
    /// actually be lighter than the bottom, and not by much.
    func testAFilledMarkIsLitFromTheTopAndOnlyJust() throws {
        let size = CGSize(width: 200, height: 200)
        var document = AnnotationDocument(imageSize: size)
        document.elements.append(AnnotationElement(kind: .counter(CounterElement(
            centre: CGPoint(x: 100, y: 100), radius: 70, number: 8,
            fill: .blue, textColour: .white))))
        let image = try XCTUnwrap(AnnotationRenderer.flatten(document, base: white(size)))
        let rep = NSBitmapImageRep(cgImage: image)

        // Sampled off the number, near the disc's top and bottom edges.
        let top = try XCTUnwrap(rep.colorAt(x: 100, y: 42))
        let bottom = try XCTUnwrap(rep.colorAt(x: 100, y: 158))
        func luma(_ c: NSColor) -> CGFloat {
            0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        }
        XCTAssertGreaterThan(luma(top), luma(bottom), "the disc should be lit from the top")
        XCTAssertLessThan(luma(top) - luma(bottom), 0.12,
                          "and subtly — past this it reads as a glossy button")
    }

    /// A finished composite: annotations, a blurred backdrop, corners, shadow and an inset.
    ///
    /// Everything below this line is exercised somewhere in isolation. This is the one picture
    /// that shows them agreeing — and the export path specifically, which assembles the background
    /// through a different function from the live canvas.
    func testTheFinishedCompositeRenders() throws {
        let size = CGSize(width: 640, height: 400)
        let shot = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Something with colour in it, so a blurred backdrop has something to be made of.
        shot.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.99, alpha: 1))
        shot.fill(CGRect(origin: .zero, size: size))
        shot.setFillColor(CGColor(srgbRed: 0.35, green: 0.30, blue: 0.85, alpha: 1))
        shot.fill(CGRect(x: 0, y: 300, width: 640, height: 100))
        shot.setFillColor(CGColor(srgbRed: 0.95, green: 0.55, blue: 0.25, alpha: 1))
        shot.fill(CGRect(x: 420, y: 60, width: 180, height: 180))
        let base = try XCTUnwrap(shot.makeImage())

        var document = AnnotationDocument(imageSize: size)
        document.elements.append(AnnotationElement(kind: .arrow(ArrowElement(
            start: CGPoint(x: 120, y: 250), end: CGPoint(x: 400, y: 130),
            curvature: ArrowGeometry.defaultCurvature(from: CGPoint(x: 120, y: 250),
                                                      to: CGPoint(x: 400, y: 130)),
            head: .curved, stroke: StrokeStyle(colour: .red, width: 14)))))
        document.elements.append(AnnotationElement(kind: .counter(CounterElement(
            centre: CGPoint(x: 470, y: 300), radius: 26, number: 1,
            fill: .blue, textColour: RGBAColour.blue.readableForeground))))

        var background = CaptureBackground()
        background.fill = .blurred(CaptureBackground.Blur(amount: 0.06, tint: -0.4))
        background.padding = 70
        background.inset = 20
        background.cornerRadius = 18
        background.alignment = .centre
        background.aspect = .sixteenNine
        document.background = background

        let flat = try XCTUnwrap(AnnotationRenderer.flatten(document, base: base))
        let composite = try XCTUnwrap(BackgroundCompositor.render(
            flat, style: background, sources: .init(base: base)))
        try write(composite, "markup-composite")

        let (canvas, imageRect) = BackgroundLayout.compute(imageSize: size, style: background)
        XCTAssertEqual(CGFloat(composite.width), canvas.width.rounded(), accuracy: 1)
        XCTAssertGreaterThanOrEqual(imageRect.minX, background.padding,
                                    "the padding is a guarantee, not slack to be spent")
    }

    /// All nine alignments, side by side.
    ///
    /// This is the bug report — "alignment does not work only left center right no top or
    /// bottom" — rendered. Nothing short of nine pictures shows that the top row and the bottom
    /// row now differ from the middle one, and the arithmetic tests cannot show that the result
    /// looks deliberate rather than broken.
    func testTheAlignmentContactSheetRenders() throws {
        let shot = CGSize(width: 240, height: 150)
        let base = try XCTUnwrap(CGContext(
            data: nil, width: Int(shot.width), height: Int(shot.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        base.setFillColor(CGColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1))
        base.fill(CGRect(origin: .zero, size: shot))
        base.setFillColor(CGColor(srgbRed: 0.35, green: 0.30, blue: 0.85, alpha: 1))
        base.fill(CGRect(x: 0, y: 110, width: 240, height: 40))
        let capture = try XCTUnwrap(base.makeImage())

        var style = CaptureBackground()
        style.fill = .builtIn(id: "dusk")
        style.padding = 40
        style.cornerRadius = 10

        var tiles: [CGImage] = []
        for alignment in Self.alignmentOrder {
            style.alignment = alignment
            tiles.append(try XCTUnwrap(BackgroundCompositor.render(capture, style: style)))
        }
        let tile = CGSize(width: CGFloat(tiles[0].width), height: CGFloat(tiles[0].height))
        let gap: CGFloat = 12
        let sheet = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(tile.width * 3 + gap * 4), height: Int(tile.height * 3 + gap * 4),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sheet.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        for (index, image) in tiles.enumerated() {
            let column = CGFloat(index % 3), row = CGFloat(2 - index / 3)   // bottom-left origin
            sheet.draw(image, in: CGRect(x: gap + column * (tile.width + gap),
                                         y: gap + row * (tile.height + gap),
                                         width: tile.width, height: tile.height))
        }
        try write(try XCTUnwrap(sheet.makeImage()), "markup-alignments")

        // And the thing the report was about: the top row and the bottom row are not the middle.
        let origins = Self.alignmentOrder.map { alignment -> CGFloat in
            style.alignment = alignment
            return BackgroundLayout.compute(imageSize: shot, style: style).imageRect.minY
        }
        XCTAssertLessThan(origins[1], origins[4], "top should sit above centre")
        XCTAssertGreaterThan(origins[7], origins[4], "bottom should sit below centre")
    }

    private static let alignmentOrder: [CaptureBackground.Alignment] = [
        .topLeading, .top, .topTrailing,
        .leading, .centre, .trailing,
        .bottomLeading, .bottom, .bottomTrailing,
    ]

    /// The drawn arrow measures what `ArrowGeometry` says it should.
    ///
    /// Rendering it and measuring the pixels back is the check the proportion tests cannot make:
    /// they assert what `metrics` returns, not what `path` does with it. Both errors this file's
    /// history records — a head that flew off at the wrong angle, and spurs on the taper — were
    /// visible in pixels while the metrics stayed correct.
    func testTheRenderedArrowMeasuresWhatTheMetricsClaim() throws {
        let size = CGSize(width: 500, height: 200)
        let width: CGFloat = 20
        let start = CGPoint(x: 60, y: 100), end = CGPoint(x: 440, y: 100)
        var document = AnnotationDocument(imageSize: size)
        document.elements.append(AnnotationElement(kind: .arrow(ArrowElement(
            start: start, end: end, head: .filled,
            stroke: StrokeStyle(colour: .red, width: width)))))
        let image = try XCTUnwrap(AnnotationRenderer.flatten(document, base: white(size)))
        try write(image, "markup-arrow-measured")

        let rep = NSBitmapImageRep(cgImage: image)
        func inked(_ x: Int) -> [Int] {
            (0..<rep.pixelsHigh).filter { y in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return c.redComponent - c.greenComponent > 0.25
            }
        }
        // A column through the middle of the shaft, well behind the head.
        let shaft = inked(120)
        XCTAssertEqual(CGFloat(shaft.count), width, accuracy: 2,
                       "the shaft should be one stroke width, with no taper")
        // A column through the tail, which the old taper drew at a third of this.
        let tail = inked(75)
        XCTAssertEqual(CGFloat(tail.count), width, accuracy: 3,
                       "the tail should be the same width as the shaft")
        // The widest column of the head.
        let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: width,
                                            length: end.x - start.x)
        // Barb tip to barb tip, measured as the ink's total extent across the axis — *not* as the
        // widest single column. The barbs are a knife edge: at the exact column through them the
        // polygon has only two isolated points plus the shaft, and one pixel forward the back
        // edges have already closed in. A column scan reads 82 where the span is 90. Measuring
        // the extent is also what was measured off the reference, so the two are comparable.
        let allInk = (Int(start.x)..<Int(end.x)).flatMap { inked($0) }
        let span = (allInk.max() ?? 0) - (allInk.min() ?? 0)
        XCTAssertEqual(CGFloat(span), metrics.headHalf * 2, accuracy: 4,
                       "barb to barb should be 2 x headHalf")
    }
}
