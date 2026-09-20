import XCTest
@testable import Sarvkrit

/// The curve a zoom travels along.
///
/// **Endpoint exactness is the whole point of this suite.** An ease that returns 0.998 instead of 1
/// leaves the frame a fraction short of its target, and the jolt when the next segment takes over
/// from a different value is visible on every zoom in the video. It is also exactly the kind of
/// error that looks like a rendering bug and gets hunted for in the compositor.
final class ZoomEaseTests: XCTestCase {

    func testEveryCurveStartsExactlyAtZero() {
        for ease in ZoomEase.allCases {
            XCTAssertEqual(ease.value(0), 0, accuracy: 1e-12, "\(ease.rawValue)")
        }
    }

    func testEveryCurveEndsExactlyAtOne() {
        for ease in ZoomEase.allCases {
            XCTAssertEqual(ease.value(1), 1, accuracy: 1e-12, "\(ease.rawValue)")
        }
    }

    func testEveryCurveIsMonotonic() {
        for ease in ZoomEase.allCases {
            var previous = -1.0
            for step in 0...100 {
                let value = ease.value(Double(step) / 100)
                XCTAssertGreaterThanOrEqual(value, previous, "\(ease.rawValue) went backwards")
                previous = value
            }
        }
    }

    /// Nothing may overshoot. A zoom that sails past its level and settles back reads as a bounce,
    /// which is charming once and seasickening over a five-minute demo.
    func testNoCurveLeavesTheUnitRange() {
        for ease in ZoomEase.allCases {
            for step in 0...100 {
                let value = ease.value(Double(step) / 100)
                XCTAssertGreaterThanOrEqual(value, 0, "\(ease.rawValue)")
                XCTAssertLessThanOrEqual(value, 1, "\(ease.rawValue)")
            }
        }
    }

    func testProgressIsClampedOutsideTheUnitRange() {
        XCTAssertEqual(ZoomEase.smooth.value(-3), 0, accuracy: 1e-12)
        XCTAssertEqual(ZoomEase.smooth.value(4), 1, accuracy: 1e-12)
    }

    func testLinearIsItsOwnProgress() {
        XCTAssertEqual(ZoomEase.linear.value(0.37), 0.37, accuracy: 1e-12)
    }

    /// A damped spring covers most of the distance early and eases into the target, so it is ahead
    /// of linear in the first half. That is what makes it read as motion with weight.
    func testSmoothLeadsLinearEarlyOn() {
        XCTAssertGreaterThan(ZoomEase.smooth.value(0.25), ZoomEase.linear.value(0.25))
    }

    /// Instant exists for cuts: the frame is at its target from the first frame, not a moment after.
    func testInstantArrivesImmediately() {
        XCTAssertEqual(ZoomEase.instant.value(0.0001), 1, accuracy: 1e-12)
    }

    // MARK: - Interpolating a level

    func testInterpolatingLandsOnBothEnds() {
        XCTAssertEqual(ZoomEase.smooth.interpolate(from: 1, to: 2.5, progress: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(ZoomEase.smooth.interpolate(from: 1, to: 2.5, progress: 1), 2.5, accuracy: 1e-12)
    }

    func testInterpolatingRunsBackwardsToo() {
        XCTAssertEqual(ZoomEase.linear.interpolate(from: 2, to: 1, progress: 0.5), 1.5, accuracy: 1e-12)
    }
}
