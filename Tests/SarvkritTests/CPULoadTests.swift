import XCTest
@testable import Sarvkrit

/// CPU usage is not a number the kernel hands out — it is a ratio between two tick counters read a
/// moment apart. The arithmetic has the same shape as `MetricRate` but a different failure mode: a
/// tick counter can legitimately produce a busy delta larger than the total delta as a core comes
/// online, and an unclamped ratio then reports 118% into a `Gauge` that draws outside its track.
final class CPULoadTests: XCTestCase {

    func testUsageIsTheBusyShareOfElapsedTicks() {
        // 100 busy ticks out of 1000 elapsed is 10%.
        XCTAssertEqual(
            CPULoad.usage(
                previous: CPUTicks(busy: 100, total: 1_000),
                current: CPUTicks(busy: 200, total: 2_000)
            ),
            10
        )
    }

    func testAFullyBusyIntervalIsOneHundredPercent() {
        XCTAssertEqual(
            CPULoad.usage(
                previous: CPUTicks(busy: 0, total: 0),
                current: CPUTicks(busy: 500, total: 500)
            ),
            100
        )
    }

    func testAFullyIdleIntervalIsZeroNotNil() {
        // An idle Mac is a real reading. It must be distinguishable from "no reading", which is
        // what the pane renders as a placeholder.
        XCTAssertEqual(
            CPULoad.usage(
                previous: CPUTicks(busy: 100, total: 1_000),
                current: CPUTicks(busy: 100, total: 2_000)
            ),
            0
        )
    }

    // MARK: - Guards

    func testNoElapsedTicksIsNilRatherThanADivisionByZero() {
        // Two samples inside one tick. Dividing by zero yields NaN, which propagates into the
        // sparkline's axis and takes the whole chart with it.
        XCTAssertNil(
            CPULoad.usage(
                previous: CPUTicks(busy: 100, total: 1_000),
                current: CPUTicks(busy: 100, total: 1_000)
            )
        )
    }

    func testCountersGoingBackwardsAreNil() {
        // Sleep and core reconfiguration can both rewind these.
        XCTAssertNil(
            CPULoad.usage(
                previous: CPUTicks(busy: 100, total: 2_000),
                current: CPUTicks(busy: 100, total: 1_000)
            )
        )
        XCTAssertNil(
            CPULoad.usage(
                previous: CPUTicks(busy: 200, total: 1_000),
                current: CPUTicks(busy: 100, total: 2_000)
            )
        )
    }

    func testABusyDeltaLargerThanTheTotalIsClampedNotReportedAsOverOneHundred() {
        // The specific reason this is clamped here rather than in the view: a core coming online
        // adds its accumulated ticks to the busy sum in one step.
        XCTAssertEqual(
            CPULoad.usage(
                previous: CPUTicks(busy: 0, total: 0),
                current: CPUTicks(busy: 1_500, total: 1_000)
            ),
            100
        )
    }
}
