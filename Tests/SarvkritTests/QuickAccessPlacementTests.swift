import XCTest
@testable import Sarvkrit

final class QuickAccessPlacementTests: XCTestCase {
    // A display with a menu bar, so visibleFrame is inset from frame at the top.
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 240, height: 160)

    func testEachCornerLandsWhereItSays() {
        let inset: CGFloat = 16
        let topLeft = QuickAccessPlacement.origin(forSize: size, corner: .topLeft, in: visible)
        XCTAssertEqual(topLeft.x, inset)
        XCTAssertEqual(topLeft.y, visible.maxY - size.height - inset)

        let bottomRight = QuickAccessPlacement.origin(forSize: size, corner: .bottomRight,
                                                      in: visible)
        XCTAssertEqual(bottomRight.x, visible.maxX - size.width - inset)
        XCTAssertEqual(bottomRight.y, inset)
    }

    func testADisplayWithANegativeOriginStillPlacesInsideItself() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let origin = QuickAccessPlacement.origin(forSize: size, corner: .bottomLeft, in: left)
        XCTAssertEqual(origin.x, -1920 + 16)
        XCTAssertGreaterThanOrEqual(origin.x, left.minX)
    }

    func testAPanelLargerThanTheScreenIsClampedNotPushedOff() {
        // Rare, but the alternative is an overlay you can't see or dismiss.
        let huge = CGSize(width: 5000, height: 5000)
        let origin = QuickAccessPlacement.origin(forSize: huge, corner: .topRight, in: visible)
        XCTAssertGreaterThanOrEqual(origin.x, visible.minX)
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY)
    }

    func testStackingRunsIntoTheScreenFromTheChosenCorner() {
        // From a top corner the pile grows downward; from a bottom corner, upward. Either way it
        // moves away from the edge it is anchored to.
        let fromTop = QuickAccessPlacement.stackOffset(forIndex: 2, size: size, corner: .topRight,
                                                       in: visible)
        XCTAssertEqual(fromTop?.height, -(160 + 8) * 2)

        let fromBottom = QuickAccessPlacement.stackOffset(forIndex: 2, size: size,
                                                          corner: .bottomRight, in: visible)
        XCTAssertEqual(fromBottom?.height, (160 + 8) * 2)
    }

    func testTheFirstThumbnailHasNoOffset() {
        XCTAssertEqual(QuickAccessPlacement.stackOffset(forIndex: 0, size: size,
                                                        corner: .topRight, in: visible),
                       CGSize(width: 0, height: 0))
    }

    func testAStackThatWouldLeaveTheScreenStopsInstead() {
        // Beyond this the newest replaces the oldest, which beats a pile walking off the edge.
        let far = QuickAccessPlacement.stackOffset(forIndex: 99, size: size,
                                                   corner: .topRight, in: visible)
        XCTAssertNil(far)
    }

    func testEveryCornerHasATitle() {
        for corner in QuickAccessPlacement.Corner.allCases {
            XCTAssertFalse(corner.title.isEmpty)
        }
    }
}

final class QuickAccessTimerTests: XCTestCase {
    private let shown = Date(timeIntervalSince1970: 1_000)

    func testItCountsDown() {
        XCTAssertEqual(QuickAccessTimer.remaining(
            now: shown.addingTimeInterval(2), shownAt: shown,
            duration: 5, hoveredSince: nil), 3)
    }

    func testAutoCloseOffNeverExpires() {
        XCTAssertNil(QuickAccessTimer.remaining(
            now: shown.addingTimeInterval(9_999), shownAt: shown,
            duration: nil, hoveredSince: nil))
        XCTAssertFalse(QuickAccessTimer.hasExpired(
            now: shown.addingTimeInterval(9_999), shownAt: shown,
            duration: nil, hoveredSince: nil))
    }

    func testHoveringPausesTheCountdownRatherThanCancellingIt() {
        // Pausing, not cancelling: an accidental pass of the pointer must not leave the overlay
        // on screen forever.
        let hoverStart = shown.addingTimeInterval(1)
        let remaining = QuickAccessTimer.remaining(
            now: shown.addingTimeInterval(60), shownAt: shown,
            duration: 5, hoveredSince: hoverStart)
        XCTAssertEqual(remaining, 4, "the clock should read what it did when the pointer arrived")
    }

    func testItExpiresOnceTheDurationHasPassed() {
        XCTAssertTrue(QuickAccessTimer.hasExpired(
            now: shown.addingTimeInterval(5), shownAt: shown,
            duration: 5, hoveredSince: nil))
        XCTAssertFalse(QuickAccessTimer.hasExpired(
            now: shown.addingTimeInterval(4.9), shownAt: shown,
            duration: 5, hoveredSince: nil))
    }

    func testItNeverGoesNegative() {
        XCTAssertEqual(QuickAccessTimer.remaining(
            now: shown.addingTimeInterval(500), shownAt: shown,
            duration: 5, hoveredSince: nil), 0)
    }
}
