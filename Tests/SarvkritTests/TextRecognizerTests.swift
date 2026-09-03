import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The boundary conversion and the shared index. Reading order itself is tested separately, over
/// synthetic boxes, because that is where the quality lives.
final class TextRecognizerTests: XCTestCase {

    func testVisionBoxesAreConvertedFromBottomLeftToTopLeft() {
        // Vision reports normalised, bottom-left-origin rects — the opposite of everything else
        // in this feature. Getting this wrong puts every highlight on the wrong line.
        let size = CGSize(width: 1000, height: 500)
        // A box hugging the TOP of the image in Vision's terms: maxY near 1.
        let top = TextRecognizer.imageRect(CGRect(x: 0, y: 0.9, width: 0.5, height: 0.1), in: size)
        XCTAssertEqual(top.minY, 0, accuracy: 0.001, "the top of the image is y = 0 for us")
        XCTAssertEqual(top.height, 50, accuracy: 0.001)
        XCTAssertEqual(top.width, 500, accuracy: 0.001)

        let bottom = TextRecognizer.imageRect(CGRect(x: 0, y: 0, width: 1, height: 0.1), in: size)
        XCTAssertEqual(bottom.maxY, 500, accuracy: 0.001)
    }

    func testThereIsAtLeastOneSupportedLanguage() {
        XCTAssertFalse(TextRecognizer.supportedLanguages.isEmpty)
    }

    /// A best-effort smoke test: renders a known string and asks Vision to read it back. Marked
    /// lenient on purpose — an OS-level recognition change should not fail CI hard, in the style
    /// of `AudioSystemSmokeTests`.
    func testItCanReadTextItWasGiven() throws {
        let width = 600, height = 160
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let string = NSAttributedString(string: "Sarvkrit", attributes: [
            .font: NSFont.systemFont(ofSize: 84, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: CGPoint(x: 30, y: 40))
        NSGraphicsContext.restoreGraphicsState()

        let image = try XCTUnwrap(context.makeImage())
        let result = TextRecognizer.recognize(image, includeBarcodes: false)

        if result.fragments.isEmpty {
            // Not a failure: recognition quality is the OS's, and this asserts our plumbing.
            return
        }
        XCTAssertTrue(result.text.lowercased().contains("sarv"),
                      "got \(result.text) — plumbing is wired but the string came back wrong")
    }
}

@MainActor
final class TextGeometryIndexTests: XCTestCase {

    /// Built by hand rather than through Vision, so the snapping rules are tested deterministically.
    private func index(withLines lines: [TextGeometryIndex.Line]) -> TextGeometryIndex {
        let index = TextGeometryIndex()
        index.setLinesForTesting(lines)
        return index
    }

    func testItFindsTheLineUnderTheCursor() {
        let index = index(withLines: [
            .init(rect: CGRect(x: 0, y: 0, width: 200, height: 20), text: "one"),
            .init(rect: CGRect(x: 0, y: 40, width: 200, height: 20), text: "two"),
        ])
        XCTAssertEqual(index.nearestLine(to: CGPoint(x: 50, y: 45), maxDistance: 30)?.text, "two")
    }

    func testTheBarSnapsToTheLineHeight() {
        let index = index(withLines: [
            .init(rect: CGRect(x: 0, y: 100, width: 300, height: 24), text: "line"),
        ])
        let bar = index.snappedBar(from: CGPoint(x: 20, y: 110), to: CGPoint(x: 220, y: 118),
                                   fallbackHeight: 40)
        XCTAssertTrue(bar.snapped)
        XCTAssertEqual(bar.rect.minY, 100)
        XCTAssertEqual(bar.rect.height, 24, "the bar takes the line's height, not the drag's")
        XCTAssertEqual(bar.rect.width, 200, "dragging only extends it sideways")
    }

    func testItFallsBackWhenNothingIsNear() {
        // What keeps the highlighter usable on a chart.
        let index = index(withLines: [
            .init(rect: CGRect(x: 0, y: 0, width: 100, height: 20), text: "far away"),
        ])
        let bar = index.snappedBar(from: CGPoint(x: 10, y: 800), to: CGPoint(x: 200, y: 800),
                                   fallbackHeight: 30)
        XCTAssertFalse(bar.snapped)
        XCTAssertEqual(bar.rect.height, 30)
    }

    func testAnIndexThatIsNotReadyNeverBlocksTheDrag() {
        // The highlighter must not wait on Vision: a drag that stalls is worse than one that
        // doesn't snap.
        let notReady = TextGeometryIndex()
        let bar = notReady.snappedBar(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0),
                                      fallbackHeight: 25)
        XCTAssertFalse(bar.snapped)
        XCTAssertEqual(bar.rect.height, 25)
    }
}
