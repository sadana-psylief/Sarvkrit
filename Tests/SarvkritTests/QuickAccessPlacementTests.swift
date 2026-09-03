import XCTest
@testable import Sarvkrit

final class QuickAccessPlacementTests: XCTestCase {

    func testEveryCornerHasATitle() {
        for corner in QuickAccessPlacement.Corner.allCases {
            XCTAssertFalse(corner.title.isEmpty)
        }
    }

    func testCornersRoundTripThroughTheirRawValues() {
        // They are persisted, so a renamed case would silently reset the user's choice.
        for corner in QuickAccessPlacement.Corner.allCases {
            XCTAssertEqual(QuickAccessPlacement.Corner(rawValue: corner.rawValue), corner)
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
