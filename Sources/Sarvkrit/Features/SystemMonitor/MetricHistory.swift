import Foundation

/// A fixed-width sliding window of readings, backing one sparkline.
///
/// Fixed width is the point. The monitor samples for as long as the app runs — days — and an
/// array that only ever grows is a leak wearing a feature's clothes. Sixty samples at the default
/// two-second interval is two minutes of history, which is as far back as a sparkline this size
/// can show anything legible anyway.
///
/// Samples are optional because `MetricRate` legitimately has nothing to report after a sleep or a
/// counter reset. Storing zero for those would draw a trough that never happened — the same
/// fabrication the rate guards exist to prevent — so a gap stays a gap all the way to the chart.
struct MetricHistory: Equatable {
    /// How many samples the window holds. Never below one: a zero-capacity window makes `append`
    /// unrepresentable and every eviction calculation negative.
    let capacity: Int

    /// Oldest first, so a chart can plot this directly without reversing it.
    private(set) var samples: [Double?] = []

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { samples.isEmpty }

    /// The largest reading still inside the window, for scaling a chart's y-axis.
    ///
    /// Gaps are skipped rather than coerced, and an all-gap window answers `nil` rather than zero —
    /// a chart that divides by a zero peak renders NaN heights. Scoped to the current window on
    /// purpose: a spike that has scrolled off must stop flattening the scale, or one burst ruins
    /// the chart for the rest of the session.
    var peak: Double? { samples.compactMap { $0 }.max() }

    mutating func append(_ value: Double?) {
        samples.append(value)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Called when the feature is switched off, and when the sampling interval changes — a window
    /// holding both 1-second and 5-second samples would silently misrepresent its own x-axis.
    mutating func clear() {
        samples.removeAll(keepingCapacity: true)
    }
}
