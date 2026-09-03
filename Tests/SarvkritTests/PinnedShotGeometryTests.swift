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

    func testAnOrdinaryNudgeMoves() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        XCTAssertEqual(
            PinnedShotGeometry.nudged(frame, by: CGSize(width: 10, height: -10),
                                      constrainedTo: displays),
            CGRect(x: 110, y: 90, width: 200, height: 200))
    }

    func testAPinCannotBeNudgedOffEveryDisplay() {
        // The one that matters: always-on-top plus off-screen equals unreachable.
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let nudged = PinnedShotGeometry.nudged(frame, by: CGSize(width: 99_999, height: 0),
                                               constrainedTo: displays)
        XCTAssertEqual(nudged, frame, "the nudge should be refused, not applied")
    }

    func testAPinCanStillMoveBetweenDisplays() {
        let two = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let frame = CGRect(x: 1300, y: 100, width: 200, height: 200)
        let nudged = PinnedShotGeometry.nudged(frame, by: CGSize(width: 300, height: 0),
                                               constrainedTo: two)
        XCTAssertEqual(nudged.minX, 1600)
    }

    func testOpacityHasAFloor() {
        // A fully transparent pin is invisible but still on screen, and while Lock Mode is off it
        // still eats clicks — a dead patch of screen the user can neither see nor dismiss.
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(0), PinnedShotGeometry.minimumOpacity)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(-5), PinnedShotGeometry.minimumOpacity)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(0.5), 0.5)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(2), 1)
    }

    func testNudgingWithNoDisplaysDoesNotTrapThePin() {
        // No displays at all happens while they are being reconfigured; refusing every move then
        // would freeze the pin permanently.
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            PinnedShotGeometry.nudged(frame, by: CGSize(width: 10, height: 0), constrainedTo: []),
            frame.offsetBy(dx: 10, dy: 0))
    }
}
