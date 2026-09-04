import XCTest
@testable import Sarvkrit

/// Synthetic display arrangements, in the style of `ScreenCoordinatesTests`.
///
/// The machine this was written on has one display, so every multi-monitor bug here is invisible
/// in manual testing — and a single-display Mac makes the two most dangerous mistakes
/// (flipping against the wrong height, assuming scale 1) correct by accident.
final class CaptureGeometryTests: XCTestCase {

    // A 1440pt-tall 2x primary at the origin.
    private let primary = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        scale: 2, pixelSize: CGSize(width: 5120, height: 2880))

    // A 1x display to the LEFT of the primary, so its origin is negative.
    private let left = DisplaySnapshotGeometry(
        displayID: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        scale: 1, pixelSize: CGSize(width: 1920, height: 1080))

    func testARectFillingATwoXDisplayIsTwiceAsManyPixels() {
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: primary.frame, in: primary)
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 5120, height: 2880))
    }

    func testTheFlipUsesTheDisplaysOwnMaxYNotThePrimarys() {
        // The whole point of this file, and it only bites when the two displays differ in height —
        // which is why this test builds its own arrangement rather than using `primary`. A short
        // primary beside a tall secondary: flipping against the primary's height would put the
        // crop off the top of the secondary's bitmap, at a negative row.
        let shortPrimary = DisplaySnapshotGeometry(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            scale: 1, pixelSize: CGSize(width: 1600, height: 1000))
        let tall = DisplaySnapshotGeometry(
            displayID: 3, frame: CGRect(x: 1600, y: 0, width: 1920, height: 1440),
            scale: 1, pixelSize: CGSize(width: 1920, height: 1440))
        let selection = CGRect(x: 1600, y: 1340, width: 100, height: 100)   // top-left of `tall`

        let correct = CaptureGeometry.pixelRect(forGlobalRect: selection, in: tall)
        XCTAssertEqual(correct.minY, 0, "top of the display must be y = 0 in its own bitmap")

        // What the mistake would produce, asserted as *different*, so this test can detect the
        // bug it exists for rather than passing under either implementation.
        let wrong = (shortPrimary.frame.maxY - selection.maxY) * tall.scale
        XCTAssertEqual(wrong, -440, "fixture no longer distinguishes the two flips")
        XCTAssertNotEqual(correct.minY, wrong)
    }

    func testANegativeOriginDisplayStillProducesNonNegativePixelCoordinates() {
        let selection = CGRect(x: -1920, y: 980, width: 200, height: 100)   // top-left of `left`
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: selection, in: left)
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertGreaterThanOrEqual(pixels.minX, 0)
        XCTAssertGreaterThanOrEqual(pixels.minY, 0)
    }

    func testAOneXAndATwoXCropTheSameGlobalSizeDifferently() {
        let size = CGRect(x: 0, y: 0, width: 100, height: 100)
        let onPrimary = CaptureGeometry.pixelRect(
            forGlobalRect: size.offsetBy(dx: 10, dy: 10), in: primary)
        let onLeft = CaptureGeometry.pixelRect(
            forGlobalRect: size.offsetBy(dx: -1910, dy: 10), in: left)
        XCTAssertEqual(onPrimary.width, 200)
        XCTAssertEqual(onLeft.width, 100)
    }

    func testPixelRectAndGlobalRectAreInverses() {
        // 1.5 is the scaled-Retina case: a display running a non-native resolution, where
        // pointPixelScale is not a power of two and naive integer maths drifts.
        for scale in [CGFloat(1.0), 2.0, 1.5] {
            let display = DisplaySnapshotGeometry(
                displayID: 9, frame: CGRect(x: -400, y: -200, width: 1600, height: 1000),
                scale: scale,
                pixelSize: CGSize(width: 1600 * scale, height: 1000 * scale))
            let original = CGRect(x: 100, y: 50, width: 320, height: 180)
            let round = CaptureGeometry.globalRect(
                forPixelRect: CaptureGeometry.pixelRect(forGlobalRect: original, in: display),
                in: display)
            XCTAssertEqual(round.minX, original.minX, accuracy: 0.0001, "scale \(scale)")
            XCTAssertEqual(round.minY, original.minY, accuracy: 0.0001, "scale \(scale)")
            XCTAssertEqual(round.width, original.width, accuracy: 0.0001, "scale \(scale)")
            XCTAssertEqual(round.height, original.height, accuracy: 0.0001, "scale \(scale)")
        }
    }

    func testASelectionIsClampedToTheDisplayItStartedOn() {
        let straddling = CGRect(x: 2400, y: 100, width: 400, height: 100)
        let clamped = CaptureGeometry.clamp(straddling, to: primary)
        XCTAssertEqual(clamped.maxX, primary.frame.maxX)
        XCTAssertEqual(clamped.width, 160)
    }

    func testDraggingUpLeftGivesTheSameRectAsDraggingDownRight() {
        let a = CaptureGeometry.selectionRect(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250),
            aspectRatio: nil, fromCenter: false)
        let b = CaptureGeometry.selectionRect(
            from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100),
            aspectRatio: nil, fromCenter: false)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testAnAspectLockedSelectionKeepsItsRatioInEveryDragDirection() {
        for target in [CGPoint(x: 400, y: 300), CGPoint(x: -400, y: 300),
                       CGPoint(x: 400, y: -300), CGPoint(x: -400, y: -300)] {
            let rect = CaptureGeometry.selectionRect(
                from: .zero, to: target, aspectRatio: 16.0 / 9.0, fromCenter: false)
            XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.0001,
                           "ratio drifted dragging toward \(target)")
            XCTAssertGreaterThan(rect.width, 0)
        }
    }

    func testResizingFromCenterGrowsBothWays() {
        let rect = CaptureGeometry.selectionRect(
            from: CGPoint(x: 500, y: 500), to: CGPoint(x: 600, y: 560),
            aspectRatio: nil, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: 400, y: 440, width: 200, height: 120))
    }

    func testSnappingProducesIntegralPixelEdgesAtTwoX() {
        // 0.25pt at 2x is half a pixel. A half-pixel crop is a blurry screenshot — the symptom
        // nobody attributes to rounding.
        let ragged = CGRect(x: 100.25, y: 200.25, width: 300.75, height: 150.25)
        let snapped = CaptureGeometry.snapToPixelGrid(ragged, in: primary)
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: snapped, in: primary)
        XCTAssertEqual(pixels.minX, pixels.minX.rounded(), accuracy: 0.0001)
        XCTAssertEqual(pixels.minY, pixels.minY.rounded(), accuracy: 0.0001)
        XCTAssertEqual(pixels.width, pixels.width.rounded(), accuracy: 0.0001)
        XCTAssertEqual(pixels.height, pixels.height.rounded(), accuracy: 0.0001)
    }

    func testTheReadoutReportsPixelsNotPoints() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(CaptureGeometry.pixelSize(of: rect, in: primary),
                       CGSize(width: 200, height: 200))
        XCTAssertEqual(CaptureGeometry.pixelSize(of: rect, in: left),
                       CGSize(width: 100, height: 100))
    }

    func testATypedPixelSizeBecomesTheRightPointRect() {
        let rect = CaptureGeometry.rect(withPixelSize: CGSize(width: 1920, height: 1080),
                                        centeredOn: CGPoint(x: 1000, y: 700), in: primary)
        XCTAssertEqual(rect.width, 960)     // 1920 px at 2x
        XCTAssertEqual(rect.height, 540)
        XCTAssertEqual(rect.midX, 1000)
        XCTAssertEqual(rect.midY, 700)
    }

    func testAPointOnNoDisplayBelongsToNothing() {
        // Returning nil rather than defaulting to the first screen: an off-screen drag that
        // silently crops the wrong display is worse than one that declines.
        XCTAssertNil(CaptureGeometry.display(containing: CGPoint(x: 99_999, y: 99_999),
                                             in: [primary, left]))
        XCTAssertEqual(CaptureGeometry.display(containing: CGPoint(x: -100, y: 100),
                                               in: [primary, left])?.displayID, left.displayID)
    }
}
