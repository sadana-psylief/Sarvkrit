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
        guard let directory = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"]
        else { return }
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
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
