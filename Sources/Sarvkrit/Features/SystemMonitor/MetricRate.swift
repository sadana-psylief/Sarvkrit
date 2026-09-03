import Foundation

/// Turns two readings of a monotonic counter into a per-second rate — or into nothing, which is the
/// interesting half.
///
/// Network bytes, disk bytes and CPU ticks are all cumulative counters, so a rate is a delta over an
/// interval. Every guard below exists because the naive division has a failure mode the user would
/// be shown as fact:
///
/// - Counters reset. Interface counters reset when the interface is reconfigured and IOKit's byte
///   counters reset on reboot, so a delta can be negative — which would render as a negative
///   download speed.
/// - Counters wrap. A 32-bit interface counter on a busy link wraps in minutes; read as `UInt64`
///   that also looks like going backwards, which is exactly the right way to treat it.
/// - Intervals lie. The Mac sleeps, and the first sample after waking spans the whole nap. The
///   delta is genuine but the *rate* is fiction: nothing moved per second while the machine was off.
///
/// In all three cases the honest answer is "no reading", and `nil` is how the pane and the menu bar
/// know to show a placeholder instead of a number. `nil` is therefore load-bearing and never a
/// silent zero — a stationary counter really is `0`, and the two must stay distinguishable.
enum MetricRate {

    /// Above this many seconds between samples, the interval is assumed to span a sleep rather than
    /// a late timer, and the rate is discarded.
    ///
    /// 30s is deliberately far above the slowest offered sampling interval (5s): a timer starved by
    /// a busy system can fire seconds late, and throwing those samples away would leave the
    /// sparkline permanently gappy under exactly the load worth watching.
    static let defaultMaxElapsed: TimeInterval = 30

    /// A per-second rate, or `nil` when the pair of readings can't support one.
    ///
    /// - Parameters:
    ///   - previous: the counter at the last sample.
    ///   - current: the counter now. Lower than `previous` means a reset or a wrap.
    ///   - elapsed: real seconds between the two readings — measured, never the nominal interval,
    ///     or every rate is quietly wrong by the timer's drift.
    ///   - maxElapsed: the sleep ceiling. Callers that sample slowly on purpose raise it.
    static func perSecond(
        previous: UInt64,
        current: UInt64,
        elapsed: TimeInterval,
        maxElapsed: TimeInterval = defaultMaxElapsed
    ) -> Double? {
        guard elapsed > 0, elapsed <= maxElapsed else { return nil }
        // Not `current - previous`: on UInt64 that traps rather than going negative.
        guard current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }
}
