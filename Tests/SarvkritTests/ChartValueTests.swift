import XCTest
@testable import Sarvkrit

/// What each metric actually hands its sparkline.
///
/// The one that matters is power. `PowerSample.watts` is signed — negative while discharging,
/// which is the ordinary state of a laptop on battery — while the rest of the Power panel reads
/// it as a magnitude: the meter plots `abs`, and the y-ceiling is `max(1, window.peak)`, which an
/// all-negative window collapses to 1. Charting the raw value therefore asked Swift Charts to
/// draw a mark at -24 against a `0...1` domain, and Charts does not clip to the plot area: the
/// area mark painted 153pt of tint straight down over the adapter, battery and health rows. The
/// sparkline is 28pt tall, so any tinted region taller than that is this bug returning.
final class ChartValueTests: XCTestCase {

    func testPowerChartsTheMagnitudeSoDischargingStaysInsideTheDomain() {
        var discharging = SystemSnapshot()
        discharging.power = PowerSample(source: .battery, watts: -24.4)
        let value = try? XCTUnwrap(discharging.chartValue(for: .power))
        XCTAssertEqual(value ?? -1, 24.4, accuracy: 0.001)

        // The ceiling the panel computes from a window of these has to be the real draw, not the
        // floor of 1 that a negative peak collapses to.
        var window = MetricHistory()
        window.append(discharging.chartValue(for: .power))
        XCTAssertEqual(try XCTUnwrap(window.peak), 24.4, accuracy: 0.001)
    }

    func testChargingIsUnchanged() {
        var charging = SystemSnapshot()
        charging.power = PowerSample(source: .adapter, watts: 41.0, adapterWatts: 96)
        XCTAssertEqual(try XCTUnwrap(charging.chartValue(for: .power)), 41.0, accuracy: 0.001)
    }

    /// An unreported amperage is a gap, not a zero — same rule as every other metric.
    func testMissingWattageIsAGapRatherThanZero() {
        var unknown = SystemSnapshot()
        unknown.power = PowerSample(source: .battery, watts: nil)
        XCTAssertNil(unknown.chartValue(for: .power))
        XCTAssertNil(SystemSnapshot().chartValue(for: .power))
    }
}
