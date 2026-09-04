import XCTest
@testable import Sarvkrit

/// A pinned screenshot is always on top, so anything that makes one unreachable — off every
/// display, or faded to nothing — is a bug the user cannot work around. Both floors are tested.
final class PinnedShotGeometryTests: XCTestCase {
    private let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

    func testResizingKeepsTheTopLeftCornerFixed() {
        let frame = CGRect(x: 100, y: 500, width: 200, height: 150)
        let resized = PinnedShotGeometry.resized(frame, by: CGSize(width: 50, height: 30),
                                                 preservingAspect: false)
        XCTAssertEqual(resized.minX, frame.minX)
        XCTAssertEqual(resized.maxY, frame.maxY, "the top edge must not move")
        XCTAssertEqual(resized.width, 250)
        XCTAssertEqual(resized.height, 180)
    }

    func testResizingBelowTheMinimumStopsAtTheMinimum() {
        // Not inverting, and not vanishing: a pin with no visible close button can't be dismissed.
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let resized = PinnedShotGeometry.resized(frame, by: CGSize(width: -500, height: -500),
                                                 preservingAspect: false)
        XCTAssertEqual(resized.width, PinnedShotGeometry.minimumSide)
        XCTAssertEqual(resized.height, PinnedShotGeometry.minimumSide)
    }

    func testAspectIsPreservedThroughAResize() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)      // 2:1
        let resized = PinnedShotGeometry.resized(frame, by: CGSize(width: 100, height: 0),
                                                 preservingAspect: true)
        XCTAssertEqual(resized.width / resized.height, 2, accuracy: 0.0001)
    }

    func testAspectSurvivesHittingTheMinimum() {
        // Clamping one axis without re-deriving the other silently changes the ratio the caller
        // asked to preserve.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)      // 2:1
        let resized = PinnedShotGeometry.resized(frame, by: CGSize(width: -10_000, height: 0),
                                                 preservingAspect: true)
        XCTAssertEqual(resized.width / resized.height, 2, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(resized.height, PinnedShotGeometry.minimumSide)
    }

    func testOpacityHasAFloor() {
        // A fully transparent pin is invisible but still on screen, and while Lock Mode is off it
        // still eats clicks — a dead patch of screen the user can neither see nor dismiss.
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(0), PinnedShotGeometry.minimumOpacity)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(-5), PinnedShotGeometry.minimumOpacity)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(0.5), 0.5)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(2), 1)
    }

}
