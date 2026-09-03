import XCTest
@testable import Sarvkrit

/// Every number the monitor shows passes through here, in a menu bar where three characters of
/// unexpected width shove every other item along. The rules are pinned because "looks right on my
/// machine at 40% CPU" has never been the same as correct at a boundary.
///
/// The placeholder is the load-bearing part: `MetricRate` returns nil for readings that genuinely
/// aren't known, and rendering those as "0" would be a confident lie.
final class MetricFormattingTests: XCTestCase {

    // MARK: - Bytes

    func testBytesBelowAKilobyteKeepTheirUnit() {
        XCTAssertEqual(MetricFormatting.bytes(0), "0 B")
        XCTAssertEqual(MetricFormatting.bytes(1), "1 B")
        XCTAssertEqual(MetricFormatting.bytes(1_023), "1023 B")
    }

    func testBytesRollOverAtExactlyTheBinaryBoundary() {
        // 1024, not 1000: memory is reported by the kernel in binary units and Activity Monitor
        // displays it that way, so matching it is what makes the two agree on screen.
        XCTAssertEqual(MetricFormatting.bytes(1_024), "1.0 KB")
        XCTAssertEqual(MetricFormatting.bytes(1_048_576), "1.0 MB")
        XCTAssertEqual(MetricFormatting.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(MetricFormatting.bytes(1_099_511_627_776), "1.0 TB")
    }

    func testBytesShowOneDecimalSoTheWidthIsStable() {
        // A value that alternates between "9 GB" and "9.7 GB" resizes the menu bar item every
        // tick. One decimal everywhere above a kilobyte keeps the width fixed.
        XCTAssertEqual(MetricFormatting.bytes(9_878_424_780), "9.2 GB")
        XCTAssertEqual(MetricFormatting.bytes(17_179_869_184), "16.0 GB")
    }

    // MARK: - Rates

    func testRatesCarryAPerSecondSuffix() {
        XCTAssertEqual(MetricFormatting.bytesPerSecond(3_250_586), "3.1 MB/s")
        XCTAssertEqual(MetricFormatting.bytesPerSecond(0), "0 B/s")
    }

    func testAnUnknownRateIsAPlaceholderNotZero() {
        // The distinction the whole nil-handling chain exists to preserve: an idle link transfers
        // zero, a link we have no reading for transfers we-don't-know.
        XCTAssertEqual(MetricFormatting.bytesPerSecond(nil), "—")
        XCTAssertNotEqual(MetricFormatting.bytesPerSecond(nil), MetricFormatting.bytesPerSecond(0))
    }

    // MARK: - Percentages

    func testPercentagesAreWholeNumbers() {
        // Sub-percent precision on a value that moves every two seconds is noise, and the extra
        // character costs menu bar width.
        XCTAssertEqual(MetricFormatting.percent(42.4), "42%")
        XCTAssertEqual(MetricFormatting.percent(42.6), "43%")
        XCTAssertEqual(MetricFormatting.percent(0), "0%")
        XCTAssertEqual(MetricFormatting.percent(100), "100%")
    }

    func testPercentagesAreClampedToWhatAMeterCanShow() {
        // Tick-delta arithmetic across a core coming online can overshoot; a Gauge given 118%
        // draws outside its track.
        XCTAssertEqual(MetricFormatting.percent(118), "100%")
        XCTAssertEqual(MetricFormatting.percent(-3), "0%")
    }

    func testAnUnknownPercentageIsAPlaceholder() {
        XCTAssertEqual(MetricFormatting.percent(nil), "—")
    }

    // MARK: - Watts

    func testDischargeIsNegativeAndChargeIsPositive() {
        // The sign is the whole message: it says which way the energy is going. A typographic
        // minus, not a hyphen, because this sits next to digits in a proportional menu bar font.
        XCTAssertEqual(MetricFormatting.watts(-8.42), "\u{2212}8.4 W")
        XCTAssertEqual(MetricFormatting.watts(42.13), "+42.1 W")
    }

    func testZeroWattsCarriesNoSign() {
        XCTAssertEqual(MetricFormatting.watts(0), "0.0 W")
    }

    func testAnUnknownWattageIsAPlaceholder() {
        // Desktops have no battery and report no amperage. That is normal, not an error.
        XCTAssertEqual(MetricFormatting.watts(nil), "—")
    }

    // MARK: - Time remaining

    func testTimeRemainingIsHoursAndPaddedMinutes() {
        XCTAssertEqual(MetricFormatting.duration(minutes: 134), "2:14")
        XCTAssertEqual(MetricFormatting.duration(minutes: 379), "6:19")
        XCTAssertEqual(MetricFormatting.duration(minutes: 65), "1:05")
    }

    func testUnderAnHourStillReadsAsATime() {
        XCTAssertEqual(MetricFormatting.duration(minutes: 7), "0:07")
    }

    func testTheCalculatingSentinelIsAPlaceholderNotANegativeClock() {
        // IOKit reports -1 while it is still working the estimate out, and 0 when there is no
        // estimate at all. Neither is a duration, and "-1:-1" has shipped in other apps.
        XCTAssertEqual(MetricFormatting.duration(minutes: -1), "—")
        XCTAssertEqual(MetricFormatting.duration(minutes: 0), "—")
        XCTAssertEqual(MetricFormatting.duration(minutes: nil), "—")
    }
}
