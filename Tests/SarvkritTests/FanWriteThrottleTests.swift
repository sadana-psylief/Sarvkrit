import XCTest
@testable import Sarvkrit

/// How often the SMC is actually written to.
///
/// The SMC is firmware on a serialised coprocessor, and the control loop runs every two seconds
/// for as long as the feature is on. Writing on every tick regardless of whether anything changed
/// would be thousands of pointless round trips an hour.
final class FanWriteThrottleTests: XCTestCase {
    private let throttle = FanWriteThrottle()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTheFirstCommandIsAlwaysWritten() {
        XCTAssertTrue(throttle.shouldWrite(
            .hold(percent: 70), lastWritten: nil, lastWriteAt: nil, now: start))
    }

    func testAnIdenticalCommandIsNotWrittenAgain() {
        XCTAssertFalse(throttle.shouldWrite(
            .hold(percent: 70), lastWritten: .hold(percent: 70),
            lastWriteAt: start, now: start.addingTimeInterval(60)))
    }

    /// Letting go is a safety action. It must never wait for a rate limit.
    func testLettingGoOfTheFanIsWrittenImmediately() {
        XCTAssertTrue(throttle.shouldWrite(
            .release(.overCeiling), lastWritten: .hold(percent: 70),
            lastWriteAt: start, now: start.addingTimeInterval(0.1)))
    }

    /// Likewise taking hold of it.
    func testTakingHoldOfTheFanIsWrittenImmediately() {
        XCTAssertTrue(throttle.shouldWrite(
            .hold(percent: 70), lastWritten: .release(.belowThreshold),
            lastWriteAt: start, now: start.addingTimeInterval(0.1)))
    }

    func testASmallSpeedChangeIsNotWorthAWrite() {
        XCTAssertFalse(throttle.shouldWrite(
            .hold(percent: 71), lastWritten: .hold(percent: 70),
            lastWriteAt: start, now: start.addingTimeInterval(60)))
    }

    func testABigSpeedChangeIsWrittenOnceTheIntervalHasPassed() {
        XCTAssertTrue(throttle.shouldWrite(
            .hold(percent: 85), lastWritten: .hold(percent: 70),
            lastWriteAt: start, now: start.addingTimeInterval(60)))
    }

    func testABigSpeedChangeWaitsForTheInterval() {
        XCTAssertFalse(throttle.shouldWrite(
            .hold(percent: 85), lastWritten: .hold(percent: 70),
            lastWriteAt: start, now: start.addingTimeInterval(0.5)))
    }
}
