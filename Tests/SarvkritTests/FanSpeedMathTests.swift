import XCTest
@testable import Sarvkrit

/// Percent-of-range is the unit the whole feature speaks, because raw RPM is not portable across
/// models and the 14"/16" MacBook Pro has two fans whose ranges differ.
final class FanSpeedMathTests: XCTestCase {

    // The measured range on Mac14,9.
    private let minimum = 2317.0
    private let maximum = 6800.0

    /// The safety property the whole design rests on, named so it cannot be refactored away by
    /// accident: there is no percent a user can choose that stops the fan.
    func testZeroPercentIsTheFanMinimumAndNeverZeroRPM() {
        XCTAssertEqual(FanSpeedMath.rpm(percent: 0, minimum: minimum, maximum: maximum), 2317)
    }

    func testOneHundredPercentIsTheFanMaximum() {
        XCTAssertEqual(FanSpeedMath.rpm(percent: 100, minimum: minimum, maximum: maximum), 6800)
    }

    func testFiftyPercentIsTheMidpointOfTheFansOwnRange() {
        XCTAssertEqual(
            FanSpeedMath.rpm(percent: 50, minimum: minimum, maximum: maximum), 4558.5, accuracy: 0.01)
    }

    func testAPercentOutsideZeroToOneHundredIsClamped() {
        XCTAssertEqual(FanSpeedMath.rpm(percent: -40, minimum: minimum, maximum: maximum), 2317)
        XCTAssertEqual(FanSpeedMath.rpm(percent: 140, minimum: minimum, maximum: maximum), 6800)
    }

    /// Two fans with different ranges land on the same fraction of their own range, not the same
    /// RPM. That is the entire reason the unit is percent.
    func testTwoFansWithDifferentRangesResolveTheSamePercentDifferently() {
        XCTAssertEqual(FanSpeedMath.rpm(percent: 70, minimum: 1200, maximum: 4400), 3440)
        XCTAssertEqual(FanSpeedMath.rpm(percent: 70, minimum: 1180, maximum: 4600), 3574)
    }

    func testRPMConvertsBackToPercent() {
        XCTAssertEqual(
            FanSpeedMath.percent(rpm: 4558.5, minimum: minimum, maximum: maximum) ?? 0,
            50, accuracy: 0.01)
    }

    /// A fan the SMC reports with no headroom cannot be controlled, and dividing by that range
    /// would be a crash rather than a dash.
    func testAFanWithNoHeadroomIsNotControllable() {
        XCTAssertFalse(FanSpeedMath.isControllable(minimum: 2317, maximum: 2317))
        XCTAssertFalse(FanSpeedMath.isControllable(minimum: 6800, maximum: 2317))
        XCTAssertNil(FanSpeedMath.percent(rpm: 3000, minimum: 2317, maximum: 2317))
    }

    /// A minimum of zero is a real range on Apple Silicon — these fans genuinely stop. It must not
    /// be treated as an absent reading the way a zero temperature is.
    func testAMinimumOfZeroIsAValidRangeNotAnAbsentOne() {
        XCTAssertTrue(FanSpeedMath.isControllable(minimum: 0, maximum: 6800))
        XCTAssertEqual(FanSpeedMath.rpm(percent: 0, minimum: 0, maximum: 6800), 0)
    }
}
