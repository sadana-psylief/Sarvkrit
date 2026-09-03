import XCTest
@testable import Sarvkrit

/// The sparkline's backing store. It is a fixed-size window on purpose — the monitor runs for as
/// long as the app does, and an unbounded array would be a slow leak dressed up as a feature.
///
/// It holds optionals rather than doubles because `MetricRate` legitimately returns nothing after a
/// sleep or a counter reset. Substituting zero for "unknown" would draw a trough that never
/// happened, which is the same lie the rate guards exist to prevent.
final class MetricHistoryTests: XCTestCase {

    func testStartsEmpty() {
        XCTAssertTrue(MetricHistory().isEmpty)
        XCTAssertTrue(MetricHistory().samples.isEmpty)
    }

    func testKeepsSamplesInTheOrderTheyArrived() {
        // Oldest first, so a chart can plot the array directly without reversing it.
        var history = MetricHistory(capacity: 4)
        history.append(1)
        history.append(2)
        history.append(3)
        XCTAssertEqual(history.samples, [1, 2, 3])
    }

    func testEvictsTheOldestSampleOnceFull() {
        // The window slides; it does not stop recording. A monitor that froze after 60 samples
        // would look identical to one that had crashed.
        var history = MetricHistory(capacity: 3)
        for value in 1...5 { history.append(Double(value)) }
        XCTAssertEqual(history.samples, [3, 4, 5])
        XCTAssertEqual(history.samples.count, history.capacity)
    }

    func testNeverGrowsBeyondCapacityUnderSustainedAppends() {
        // The leak this type exists to prevent, asserted rather than assumed.
        var history = MetricHistory(capacity: 60)
        for index in 0..<10_000 { history.append(Double(index)) }
        XCTAssertEqual(history.samples.count, 60)
    }

    func testAMissingReadingIsStoredAsAGapNotAZero() {
        // After a wake, `MetricRate` returns nil. Recording 0 would show as a dip to idle; a gap
        // shows as a break in the line, which is what actually happened.
        var history = MetricHistory(capacity: 4)
        history.append(10)
        history.append(nil)
        history.append(20)
        XCTAssertEqual(history.samples, [10, nil, 20])
        XCTAssertFalse(history.isEmpty, "a gap is still a recorded sample")
    }

    // MARK: - Scaling the chart

    func testPeakIgnoresGaps() {
        // The y-axis is scaled to the peak. A nil treated as a number would either crash the
        // comparison or, worse, silently coerce to zero and rescale the whole chart.
        var history = MetricHistory(capacity: 4)
        history.append(5)
        history.append(nil)
        history.append(12)
        XCTAssertEqual(history.peak, 12)
    }

    func testPeakIsNilWhenEveryReadingIsAGap() {
        // A chart with nothing to scale against must be told so, not handed zero — dividing by a
        // zero peak is how sparklines end up rendering NaN heights.
        var history = MetricHistory(capacity: 3)
        history.append(nil)
        history.append(nil)
        XCTAssertNil(history.peak)
    }

    func testPeakReflectsOnlyTheCurrentWindow() {
        // A spike that has scrolled off must stop flattening the chart, or one burst permanently
        // ruins the scale for the rest of the session.
        var history = MetricHistory(capacity: 3)
        history.append(1_000)
        history.append(1)
        history.append(2)
        history.append(3)
        XCTAssertEqual(history.peak, 3)
    }

    // MARK: - Clearing

    func testClearEmptiesTheWindowAndKeepsTheCapacity() {
        // Called when the feature is switched off and when the sampling interval changes — mixing
        // 1s and 5s samples in one window would silently distort the x-axis.
        var history = MetricHistory(capacity: 5)
        history.append(1)
        history.append(2)
        history.clear()
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.peak)
        XCTAssertEqual(history.capacity, 5, "clearing must not reset the window size")
    }

    func testACapacityBelowOneIsRefusedRatherThanCrashing() {
        // Defensive: a zero capacity would make `append` unrepresentable and every slide-off
        // arithmetic negative.
        XCTAssertEqual(MetricHistory(capacity: 0).capacity, 1)
        XCTAssertEqual(MetricHistory(capacity: -5).capacity, 1)
    }
}
