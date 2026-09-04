import XCTest
@testable import Sarvkrit

/// Loupe sampling, which is all edge cases.
///
/// `CGImage.cropping(to:)` returns nil for a rect that isn't wholly inside the image, so a
/// naive implementation makes the magnifier disappear exactly where it matters most — on the
/// screen edge you are trying to line a selection up against.
final class MagnifierSamplerTests: XCTestCase {
    private let display = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        scale: 2, pixelSize: CGSize(width: 2000, height: 1600))

    func testTheLoupeIsCentredOnThePointerInTheMiddleOfTheScreen() {
        let rect = try! XCTUnwrap(MagnifierSampler.sourceRect(
            around: CGPoint(x: 500, y: 400), tileCount: 9, in: display))
        XCTAssertEqual(rect.width, 9)
        XCTAssertEqual(rect.height, 9)
        // 500pt from the left at 2x is pixel 1000; the 9-wide window starts 4 before it.
        XCTAssertEqual(rect.minX, 996)
    }

    func testTheFlipIsVerticalSoTheTopOfTheScreenIsRowZero() {
        let rect = try! XCTUnwrap(MagnifierSampler.sourceRect(
            around: CGPoint(x: 500, y: 800), tileCount: 9, in: display))
        XCTAssertEqual(rect.minY, 0, "the top edge in AppKit points is row 0 in the bitmap")
    }

    func testACornerPointerStillProducesAFullSizedRectInsideTheImage() {
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 800),
                       CGPoint(x: 0, y: 800), CGPoint(x: 1000, y: 0)] {
            let rect = try! XCTUnwrap(MagnifierSampler.sourceRect(
                around: corner, tileCount: 9, in: display))
            XCTAssertEqual(rect.width, 9, "the loupe must not shrink at \(corner)")
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, display.pixelSize.width)
            XCTAssertLessThanOrEqual(rect.maxY, display.pixelSize.height)
        }
    }

    func testTheCrosshairFollowsThePointerWhenTheRectSlidesAwayFromAnEdge() {
        // Sliding the window keeps the loupe full-sized, but the reported pixel must still be the
        // one under the pointer — otherwise the colour readout is subtly wrong near an edge.
        let corner = CGPoint(x: 0, y: 800)
        let rect = try! XCTUnwrap(MagnifierSampler.sourceRect(
            around: corner, tileCount: 9, in: display))
        let offset = MagnifierSampler.centreOffset(around: corner, sourceRect: rect, in: display)
        XCTAssertEqual(offset, CGPoint(x: 0, y: 0))

        let middle = CGPoint(x: 500, y: 400)
        let midRect = try! XCTUnwrap(MagnifierSampler.sourceRect(
            around: middle, tileCount: 9, in: display))
        XCTAssertEqual(MagnifierSampler.centreOffset(around: middle, sourceRect: midRect,
                                                     in: display),
                       CGPoint(x: 4, y: 4))
    }

    func testADisplaySmallerThanTheLoupeSamplesNothing() {
        let tiny = DisplaySnapshotGeometry(
            displayID: 2, frame: CGRect(x: 0, y: 0, width: 4, height: 4),
            scale: 1, pixelSize: CGSize(width: 4, height: 4))
        XCTAssertNil(MagnifierSampler.sourceRect(around: .zero, tileCount: 9, in: tiny))
    }

    func testANegativeOriginDisplaySamplesFromItsOwnBitmap() {
        let left = DisplaySnapshotGeometry(
            displayID: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            scale: 1, pixelSize: CGSize(width: 1920, height: 1080))
        let rect = try! XCTUnwrap(MagnifierSampler.sourceRect(
            around: CGPoint(x: -1920 + 500, y: 1080 - 300), tileCount: 11, in: left))
        XCTAssertEqual(rect.minX, 495)
        XCTAssertEqual(rect.minY, 295)
    }
}
