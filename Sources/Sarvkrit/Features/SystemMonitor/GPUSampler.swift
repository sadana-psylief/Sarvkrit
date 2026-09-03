import Foundation

/// GPU utilisation, from the accelerator's own performance counters.
///
/// `Device Utilization %` under `PerformanceStatistics` is the same figure Activity Monitor's GPU
/// history draws, and it needs no privileges. It is not a documented API, so every step is
/// optional and a Mac that doesn't report it yields nil rather than a zero — a flat zero line
/// would read as "your GPU is idle" on a machine that simply never answered.
///
/// The maximum across accelerators, not the sum: an Intel Mac with discrete graphics presents two,
/// and adding their percentages produces readings above 100.
enum GPUSampler {
    static func readUtilization() -> Double? {
        var highest: Double?
        for properties in IORegistryProperties.all(matching: "IOAccelerator") {
            guard let statistics = properties["PerformanceStatistics"] as? [String: Any],
                  let utilization = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            highest = max(highest ?? 0, utilization)
        }
        return highest
    }
}
