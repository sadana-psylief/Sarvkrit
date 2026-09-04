import Foundation

/// Which part of the Mac a temperature sensor is measuring, worked out from its name.
///
/// A pure name-to-sensor table, and the only part of the thermal path that can be tested at all.
/// The sampler around it needs a live HID client and hardware that answers; this needs a string.
/// It is also the part most likely to be wrong on a Mac other than the one it was written on, which
/// is exactly why it is a table someone can read and add a row to rather than a chain of
/// `contains` calls buried in the sampler.
///
/// Names observed on Apple Silicon, from `IOHIDServiceClient`'s `Product` property:
///
/// ```
/// PMU TP0s, PMU TP1g, PMU TP2s …   CPU core clusters (g = performance, s = efficiency)
/// PMU tdie0 … PMU tdie10           SoC die
/// PMU tdev1 … PMU tdev8            board devices
/// PMU tcal                         calibration reference
/// gas gauge battery                battery
/// NAND CH0 temp                    SSD
/// ```
///
/// Earlier Apple Silicon reports `pACC MTR Temp Sensor1`, `eACC …` and `GPU MTR Temp Sensor1`
/// instead, so both spellings are matched.
enum ThermalSensor: Equatable {
    case cpu
    case gpu
    /// The SoC die as a whole. Used for the CPU only when no core-cluster sensor answered — it is
    /// the same piece of silicon, measured less specifically.
    case soc
    case battery

    /// `nil` for a sensor that measures something we don't report, or that isn't a temperature of
    /// the machine at all.
    static func classify(_ name: String) -> ThermalSensor? {
        // Calibration first, and by exact match. `tcal` is a fixed reference that reads ~52°C on an
        // idle Mac; folded into the SoC group it would silently become the reported temperature,
        // since these are combined by taking the maximum.
        if name == "PMU tcal" { return nil }

        if name.hasPrefix("PMU TG") || name.hasPrefix("GPU ") { return .gpu }
        if name.hasPrefix("PMU TP") || name.hasPrefix("pACC ") || name.hasPrefix("eACC ") {
            return .cpu
        }
        if name.hasPrefix("PMU tdie") || name.hasPrefix("SOC ") { return .soc }
        if name.contains("gas gauge battery") { return .battery }
        return nil
    }

    /// Reduces a set of readings to the one number per part that gets shown.
    ///
    /// The **maximum**, not the mean. Six core-cluster sensors disagree by a few degrees and the
    /// question anyone asks a CPU temperature is how close it is to throttling, which is a property
    /// of the hottest cluster. Averaging buries exactly the reading worth seeing.
    ///
    /// A Mac reporting no core-cluster sensor falls back to the SoC die, which is the same silicon
    /// measured less precisely — better than a dash, and never used when something more specific
    /// answered.
    static func reduce(_ readings: [(sensor: ThermalSensor, celsius: Double)])
        -> (cpu: Double?, gpu: Double?) {
        func peak(_ sensor: ThermalSensor) -> Double? {
            readings.filter { $0.sensor == sensor }.map(\.celsius).max()
        }
        return (cpu: peak(.cpu) ?? peak(.soc), gpu: peak(.gpu))
    }

    /// Readings outside this range are discarded as nonsense rather than shown.
    ///
    /// A sensor that has not been read since boot reports 0, and a disconnected one reports values
    /// in the hundreds. Both format perfectly well and would be believed.
    static func isPlausible(celsius: Double) -> Bool {
        celsius > 0 && celsius < 150
    }
}
