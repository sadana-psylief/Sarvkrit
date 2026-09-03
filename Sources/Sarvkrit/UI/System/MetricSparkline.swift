import Charts
import SwiftUI

/// One metric's history as a small line-and-area chart.
///
/// Its own view because the awkward cases live here rather than in the pane: a window that is
/// entirely gaps, a peak of zero on an idle machine, and a single sample before any rate exists.
/// Each is a way to hand a chart an empty y-domain and get NaN geometry, so the floor on the
/// y-scale is load-bearing rather than defensive tidiness.
///
/// Swift Charts rather than a hand-drawn path, per `Tokens.swift`: never hand-roll a control the
/// system already provides.
struct MetricSparkline: View {
    let window: MetricHistory
    /// The y-axis maximum. Percentages pass 100 so the line means the same thing at every glance;
    /// rates have no natural ceiling and pass their own peak.
    let ceiling: Double

    /// One sample, tagged with which unbroken run of readings it belongs to.
    private struct Point: Identifiable {
        let id: Int
        let value: Double
        /// Charts joins marks within a series and never across series, so incrementing this at
        /// every gap is what actually breaks the line.
        let run: Int
    }

    /// Splits the window into runs of consecutive real readings.
    ///
    /// Simply omitting the gaps — the obvious version — looks completely continuous: Charts
    /// interpolates between the samples either side, drawing a confident line across a stretch
    /// where nothing was measured. That was visible only once the chart was rendered and looked
    /// at, which is why the gaps are modelled rather than filtered.
    private var points: [Point] {
        var points: [Point] = []
        var run = 0
        var inGap = true
        for (index, sample) in window.samples.enumerated() {
            guard let sample else {
                inGap = true
                continue
            }
            if inGap {
                run += 1
                inGap = false
            }
            points.append(Point(id: index, value: sample, run: run))
        }
        return points
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Sample", point.id),
                y: .value("Value", point.value),
                series: .value("Run", point.run)
            )
            .foregroundStyle(Color.accentColor.opacity(0.22))

            LineMark(
                x: .value("Sample", point.id),
                y: .value("Value", point.value),
                series: .value("Run", point.run)
            )
            .foregroundStyle(Color.accentColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        // Fixed to the window's capacity, so the line grows in from the left as history fills
        // rather than stretching two samples across the full width.
        .chartXScale(domain: 0...Double(max(1, window.capacity - 1)))
        // The floor is what keeps an all-gap or all-zero window from producing a 0...0 domain.
        .chartYScale(domain: 0...max(1, ceiling))
        .frame(width: 110, height: 24)
        // The number beside it already says everything this conveys.
        .accessibilityHidden(true)
    }
}
