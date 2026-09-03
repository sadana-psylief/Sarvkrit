import XCTest
@testable import Sarvkrit

/// Every rate this app shows — network, disk throughput, CPU — is a delta between two readings of a
/// counter that only ever climbs. The arithmetic is trivial; the edge cases are not, and each one
/// has a visible failure mode. A counter that resets on reboot would render as a negative download
/// speed. A sleeping Mac hands back an hour-wide interval whose delta, divided by the *expected*
/// interval, is a spike that never happened. Both of those are shown to the user as fact, so the
/// rules live here in one pure place and are pinned exhaustively.
final class MetricRateTests: XCTestCase {

    // MARK: - The ordinary case

    func testRateIsBytesPerSecondOverTheElapsedTime() {
        // 1024 bytes across 2 seconds is 512 B/s. Nothing subtle, but it is the case that must
        // survive every guard added below.
        XCTAssertEqual(
            MetricRate.perSecond(previous: 1_000, current: 2_024, elapsed: 2),
            512
        )
    }

    func testAStationaryCounterIsZeroNotNil() {
        // An idle network genuinely transfers nothing. Zero is the honest answer and must be
        // distinguishable from "we don't know" — the pane renders those differently.
        XCTAssertEqual(MetricRate.perSecond(previous: 5_000, current: 5_000, elapsed: 2), 0)
    }

    func testFractionalIntervalsScaleUp() {
        // A 1-second timer does not fire at exactly 1.000s. Rates must use the real elapsed time
        // rather than the nominal interval, or every reading is quietly wrong by the drift.
        XCTAssertEqual(
            XCTUnwrap_(MetricRate.perSecond(previous: 0, current: 100, elapsed: 0.5)),
            200,
            accuracy: 0.001
        )
    }

    // MARK: - A counter that went backwards

    func testACounterGoingBackwardsIsNilNotANegativeRate() {
        // Interface counters reset when the interface is reconfigured, and IOKit's byte counters
        // reset on reboot. Reporting "-4 MB/s" would be worse than reporting nothing.
        XCTAssertNil(MetricRate.perSecond(previous: 2_000, current: 1_000, elapsed: 2))
    }

    func testTheSampleAfterAResetRecoversRatherThanStayingBroken() {
        // The reset itself yields nil; the *next* pair must work normally, because the sampler
        // rebaselines. This is what stops one reboot poisoning the reading until relaunch.
        XCTAssertNil(MetricRate.perSecond(previous: 2_000, current: 10, elapsed: 2))
        XCTAssertEqual(MetricRate.perSecond(previous: 10, current: 1_034, elapsed: 2), 512)
    }

    // MARK: - Intervals that can't be trusted

    func testZeroElapsedIsNilRatherThanADivisionByZero() {
        // Two samples in the same instant. Dividing by zero yields .infinity, which formats as
        // "inf B/s" and propagates into the sparkline's axis.
        XCTAssertNil(MetricRate.perSecond(previous: 0, current: 1_024, elapsed: 0))
    }

    func testNegativeElapsedIsNil() {
        // A clock adjustment can move wall time backwards between samples.
        XCTAssertNil(MetricRate.perSecond(previous: 0, current: 1_024, elapsed: -2))
    }

    func testAnIntervalWideEnoughToBeASleepIsNil() {
        // The specific bug this guard exists for: the Mac sleeps, and the first sample after wake
        // spans the whole nap. The delta is real but the rate is meaningless — nothing was
        // transferred *per second* over an hour of being switched off.
        XCTAssertNil(MetricRate.perSecond(previous: 0, current: 5_000_000_000, elapsed: 3_600))
    }

    func testTheSleepCeilingIsGenerousEnoughForALateTimer() {
        // A timer starved by a busy system can fire seconds late. That is not a sleep, and
        // discarding those samples would leave the sparkline permanently gappy under load.
        XCTAssertEqual(
            MetricRate.perSecond(previous: 0, current: 1_000, elapsed: 10),
            100
        )
    }

    func testTheCeilingIsConfigurableForCallersThatSampleSlowly() {
        // Disk capacity and other slow metrics may legitimately sample minutes apart. The rule is
        // "implausibly longer than intended", which only the caller knows.
        XCTAssertEqual(
            MetricRate.perSecond(previous: 0, current: 600, elapsed: 300, maxElapsed: 600),
            2
        )
    }

    // MARK: - Counter width

    func testAWrapAroundIsTreatedAsAResetNotAHugeNumber() {
        // 32-bit interface counters on a busy link wrap in minutes. Read as UInt64 the value
        // appears to fall, which the backwards guard already covers — this pins that a wrap can
        // never be mistaken for ~18 exabytes of traffic.
        XCTAssertNil(MetricRate.perSecond(previous: UInt64.max - 10, current: 5, elapsed: 2))
    }

    // MARK: -

    /// `XCTUnwrap` is throwing; these assertions are inside non-throwing tests on purpose so the
    /// failure reads as a value mismatch rather than an unrelated thrown error.
    private func XCTUnwrap_(_ value: Double?) -> Double {
        guard let value else {
            XCTFail("expected a rate, got nil")
            return .nan
        }
        return value
    }
}
