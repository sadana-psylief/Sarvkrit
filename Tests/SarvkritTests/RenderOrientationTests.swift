import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Orientation, which shipped wrong.
///
/// `CGContext.draw(_:in:)` places an image bottom-up in the current coordinate system. Every
/// context in this feature is flipped to a top-left origin so document coordinates read naturally,
/// which meant the screenshot came out upside down while the annotations drawn over it came out
/// the right way up. It looked like the capture was broken rather than the drawing code.
final class RenderOrientationTests: XCTestCase {

    /// An image whose top half is red and bottom half is blue.
    private func topRedBottomBlue(_ width: Int = 20, _ height: Int = 20) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // CGContext is bottom-left, so the *upper* half is drawn at the high y values.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    /// (r, g, b) at a pixel, indexed from the **top** of the image.
    private func pixel(_ image: CGImage, x: Int, yFromTop: Int) throws -> (Int, Int, Int) {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(buffer.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // A bitmap context's *memory* starts at the top-left pixel even though its *drawing*
        // origin is bottom-left, so buffer row n is display row n from the top. The fixture
        // self-check above is what pins this, because getting it backwards would make every
        // assertion below pass for the wrong reason.
        let offset = (yFromTop * image.width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
    }

    func testTheFixtureItselfIsTheRightWayUp() throws {
        // If this fails the other assertions mean nothing.
        let base = try topRedBottomBlue()
        let top = try pixel(base, x: 10, yFromTop: 2)
        let bottom = try pixel(base, x: 10, yFromTop: 17)
        XCTAssertGreaterThan(top.0, 200, "the top should be red")
        XCTAssertGreaterThan(bottom.2, 200, "the bottom should be blue")
    }

    func testFlatteningKeepsTheImageTheRightWayUp() throws {
        let base = try topRedBottomBlue()
        let document = AnnotationDocument(imageSize: CGSize(width: 20, height: 20))
        let flattened = try XCTUnwrap(AnnotationRenderer.flatten(document, base: base))

        let top = try pixel(flattened, x: 10, yFromTop: 2)
        let bottom = try pixel(flattened, x: 10, yFromTop: 17)
        XCTAssertGreaterThan(top.0, 200, "the top of a flattened capture must still be red")
        XCTAssertGreaterThan(bottom.2, 200, "and the bottom still blue")
    }

    func testAnAnnotationLandsWhereItsCoordinatesSay() throws {
        // The other half of the same bug: if the image is flipped but the marks are not, they end
        // up over the wrong part of the picture.
        let base = try topRedBottomBlue(40, 40)
        var document = AnnotationDocument(imageSize: CGSize(width: 40, height: 40))
        // A filled green box over the TOP-LEFT quarter, in top-left document coordinates.
        document.add(.rectangle(ShapeElement(
            rect: CGRect(x: 0, y: 0, width: 20, height: 20),
            stroke: StrokeStyle(colour: .green, width: 1), fill: .green)))

        let flattened = try XCTUnwrap(AnnotationRenderer.flatten(document, base: base))
        let topLeft = try pixel(flattened, x: 5, yFromTop: 5)
        let bottomLeft = try pixel(flattened, x: 5, yFromTop: 34)

        XCTAssertGreaterThan(topLeft.1, 150, "the mark belongs at the top, over the red")
        XCTAssertGreaterThan(bottomLeft.2, 150, "and the bottom should be untouched blue")
    }

    func testCompositingOntoABackgroundKeepsOrientation() throws {
        let base = try topRedBottomBlue(40, 40)
        var style = CaptureBackground()
        style.padding = 10
        style.aspect = .free
        style.shadow = nil
        style.cornerRadius = 0

        let composed = try XCTUnwrap(BackgroundCompositor.render(base, style: style))
        XCTAssertEqual(composed.width, 60)

        // Inside the padded frame: the screenshot's own top should still be red.
        let top = try pixel(composed, x: 30, yFromTop: 14)
        let bottom = try pixel(composed, x: 30, yFromTop: 45)
        XCTAssertGreaterThan(top.0, 150, "the composited screenshot must not be upside down")
        XCTAssertGreaterThan(bottom.2, 150)
    }

    func testTheCompositionMatchesWhatTheEditorLaysOut() throws {
        // The canvas and the export both go through `composition(for:)`, so a background can never
        // preview at one size and export at another.
        var document = AnnotationDocument(imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(AnnotationRenderer.composition(for: document).canvasSize,
                       CGSize(width: 200, height: 100))
        XCTAssertEqual(AnnotationRenderer.composition(for: document).imageRect.origin, .zero)

        var style = CaptureBackground()
        style.padding = 30
        style.aspect = .free
        document.background = style
        let withBackground = AnnotationRenderer.composition(for: document)
        XCTAssertEqual(withBackground.canvasSize, CGSize(width: 260, height: 160))
        XCTAssertEqual(withBackground.imageRect, CGRect(x: 30, y: 30, width: 200, height: 100))
    }
}
