import Foundation

/// Cumulative CPU tick counters, summed across every core.
///
/// `busy` is user + system + nice; `total` adds idle. Both only climb, so usage is the ratio of
/// their deltas — the kernel never reports a percentage directly.
struct CPUTicks: Equatable {
    var busy: UInt64
    var total: UInt64
}

/// The busy share of the ticks that elapsed between two readings.
///
/// Same shape as `MetricRate` but a failure mode of its own: as a core comes online its accumulated
/// ticks join the busy sum in a single step, so the busy delta can exceed the total delta. Unclamped
/// that reports 118%, and a `Gauge` handed 118% draws outside its own track — which is why the
/// clamp lives here, in the tested layer, rather than in a view.
enum CPULoad {
    static func usage(previous: CPUTicks, current: CPUTicks) -> Double? {
        // Neither counter may rewind: sleep and core reconfiguration can both do it.
        guard current.total >= previous.total, current.busy >= previous.busy else { return nil }

        let elapsed = current.total - previous.total
        // Two samples inside one tick. Dividing by zero yields NaN, which propagates into the
        // sparkline's axis and takes the whole chart with it.
        guard elapsed > 0 else { return nil }

        let busy = current.busy - previous.busy
        return min(100, Double(busy) / Double(elapsed) * 100)
    }
}
