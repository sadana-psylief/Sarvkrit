import XCTest
@testable import Sarvkrit

final class ScrollQuiescenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testItWaitsForTheScrollToSettle() {
        // Mid-flick: the page is still moving, so a frame taken now would be blurred and its
        // overlap with the previous one meaningless.
        XCTAssertFalse(ScrollQuiescence.shouldCapture(
            lastEventAt: now.addingTimeInterval(-0.05), lastCaptureAt: nil, now: now))
    }

    func testItCapturesOnceTheScrollHasStopped() {
        XCTAssertTrue(ScrollQuiescence.shouldCapture(
            lastEventAt: now.addingTimeInterval(-0.2), lastCaptureAt: nil, now: now))
    }

    func testMomentumIsHandledByWaitingRatherThanByCounting() {
        // Inertial scrolling keeps delivering events as it decelerates; each one pushes the
        // deadline out, so the frame lands after the page settles rather than during the glide.
        var lastEvent = now
        for step in 0..<10 {
            lastEvent = now.addingTimeInterval(Double(step) * 0.04)
            XCTAssertFalse(ScrollQuiescence.shouldCapture(
                lastEventAt: lastEvent, lastCaptureAt: nil,
                now: lastEvent.addingTimeInterval(0.04)))
        }
        XCTAssertTrue(ScrollQuiescence.shouldCapture(
            lastEventAt: lastEvent, lastCaptureAt: nil,
            now: lastEvent.addingTimeInterval(0.2)))
    }

    func testAStillPageIsNotCapturedOverAndOver() {
        // Otherwise reading the page for ten seconds fills the frame budget with identical shots.
        let event = now.addingTimeInterval(-1)
        XCTAssertFalse(ScrollQuiescence.shouldCapture(
            lastEventAt: event, lastCaptureAt: now.addingTimeInterval(-0.5), now: now))
    }

    func testScrollingAgainAfterAPauseCapturesAgain() {
        XCTAssertTrue(ScrollQuiescence.shouldCapture(
            lastEventAt: now.addingTimeInterval(-0.2),
            lastCaptureAt: now.addingTimeInterval(-5), now: now))
    }

    func testNothingHappensBeforeTheFirstScroll() {
        XCTAssertFalse(ScrollQuiescence.shouldCapture(
            lastEventAt: nil, lastCaptureAt: nil, now: now))
    }
}
