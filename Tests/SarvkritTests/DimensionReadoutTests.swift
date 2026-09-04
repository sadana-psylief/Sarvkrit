import XCTest
@testable import Sarvkrit

final class DimensionReadoutTests: XCTestCase {

    func testItUsesAMultiplicationSignNotAnX() {
        XCTAssertEqual(DimensionReadout.text(for: CGSize(width: 1920, height: 1080)),
                       "1920 × 1080")
    }

    func testItReportsPixelsNotPoints() {
        // The number the user wants is the one that will be in the file. Reporting points would
        // say 960 × 540 for a Retina capture that produces a 1920 × 1080 PNG.
        let display = DisplaySnapshotGeometry(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            scale: 2, pixelSize: CGSize(width: 2000, height: 1600))
        let pixels = CaptureGeometry.pixelSize(
            of: CGRect(x: 0, y: 0, width: 960, height: 540), in: display)
        XCTAssertEqual(DimensionReadout.text(for: pixels), "1920 × 1080")
    }

    func testTheScaleSuffixOnlyAppearsAboveOneX() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(DimensionReadout.text(for: size, scale: 1), "800 × 600")
        XCTAssertEqual(DimensionReadout.text(for: size, scale: 2), "800 × 600 @2x")
    }

    func testAScaledResolutionHasNoTrailingZero() {
        XCTAssertEqual(DimensionReadout.text(for: CGSize(width: 100, height: 100), scale: 1.5),
                       "100 × 100 @1.5x")
    }

    func testFractionalPixelsAreRounded() {
        XCTAssertEqual(DimensionReadout.text(for: CGSize(width: 100.6, height: 50.4)),
                       "101 × 50")
    }
}
