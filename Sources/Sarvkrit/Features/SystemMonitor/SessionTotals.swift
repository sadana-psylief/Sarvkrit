import Foundation

/// How much has moved since the monitor was switched on.
///
/// A running total, not a rate, and it answers a different question: "how much have I used today"
/// rather than "how fast is it going right now". Kept from the moment the feature starts, so it
/// resets when the user switches the monitor off and on again — that is the session it is named
/// after, not the uptime of the Mac, which Sarvkrit has no record of across launches and would
/// have to invent.
///
/// Pure and injectable for the same reason `MetricRate` is: every interesting case is a counter
/// behaving badly, and none of them can be reproduced on demand against a real interface.
struct SessionTotals: Equatable {
    private(set) var total: UInt64 = 0
    private var previous: UInt64?

    /// Folds in the next reading of a cumulative counter.
    ///
    /// Shares `MetricRate`'s reading of what a *decrease* means — a reset or a wrap — but not what
    /// it does about it. A rate discards the sample, because there is no honest per-second number
    /// to report. A total cannot discard anything without losing everything counted so far, so it
    /// re-baselines instead: what accumulated stays, and counting resumes from the new value. The
    /// alternative, adding `current` outright, credits the session with the counter's whole history
    /// the first time an interface is reconfigured.
    ///
    /// A sleep gap is deliberately *not* excluded, unlike in `MetricRate`. Bytes that moved before
    /// the Mac slept really did move; it is only the per-second figure that becomes fiction.
    mutating func add(counter current: UInt64) {
        defer { previous = current }
        guard let previous else { return }
        guard current >= previous else { return }
        total += current - previous
    }

    mutating func reset() {
        self = SessionTotals()
    }
}
