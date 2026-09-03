import Foundation
import IOKit.ps

/// One pass over the power hardware, projected into the two domains the user sees separately.
///
/// Battery and Power are distinct rows in the pane, but they come from the same registry: charge
/// and time remaining from the documented `IOPowerSources` API, amperage and voltage from
/// `AppleSmartBattery`. Reading once and projecting twice is what keeps enabling both from costing
/// two IOKit passes every tick.
///
/// The division of labour matters. Charge comes from `IOPSCopyPowerSourcesInfo`, which reports a
/// normalised percentage; `AppleSmartBattery`'s own `CurrentCapacity`/`MaxCapacity` look like mAh
/// but are already percentages on Apple Silicon, and treating them as capacities gives a number
/// that happens to be right for the wrong reason and breaks on other hardware.
enum PowerSourceReader {
    struct Reading: Equatable {
        var battery: BatterySample
        var power: PowerSample
    }

    static func read() -> Reading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        let adapterWatts = readAdapterWatts()
        let registry = readBatteryRegistry()

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
            else { continue }

            return Reading(
                battery: battery(from: description, registry: registry),
                power: power(from: description, registry: registry, adapterWatts: adapterWatts)
            )
        }

        // No internal battery: a desktop, which is a normal answer and not a failure. `isPresent`
        // false is what stops the pane rendering a confident 0%.
        return Reading(
            battery: BatterySample(percent: 0, isCharging: false, isPresent: false),
            power: PowerSample(source: .adapter, watts: nil, adapterWatts: adapterWatts)
        )
    }

    // MARK: - Projections

    private static func battery(
        from description: [String: Any],
        registry: BatteryRegistry?
    ) -> BatterySample {
        let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue ?? 0
        let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue ?? 0
        let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false

        // Which estimate applies depends on direction; the other is reported as -1.
        let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = (description[minutesKey as String] as? NSNumber)?.intValue

        return BatterySample(
            percent: maximum > 0 ? current / maximum * 100 : 0,
            isCharging: isCharging,
            isPresent: true,
            // -1 means "still working it out" and 0 means "no estimate"; MetricFormatting renders
            // both as a placeholder rather than as a clock.
            minutesRemaining: minutes,
            cycleCount: registry?.cycleCount
        )
    }

    private static func power(
        from description: [String: Any],
        registry: BatteryRegistry?,
        adapterWatts: Int?
    ) -> PowerSample {
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        let source: PowerSample.Source = state == (kIOPSACPowerValue as String) ? .adapter : .battery

        let watts = registry.flatMap {
            BatteryMath.watts(milliamps: $0.milliamps, millivolts: $0.millivolts)
        }
        return PowerSample(
            source: source,
            watts: watts,
            adapterWatts: source == .adapter ? adapterWatts : nil
        )
    }

    // MARK: - The registry half

    private struct BatteryRegistry {
        var milliamps: Int
        var millivolts: Int
        var cycleCount: Int?
    }

    private static func readBatteryRegistry() -> BatteryRegistry? {
        guard let properties = IORegistryProperties.first(matching: "AppleSmartBattery") else {
            return nil
        }
        // Read as raw bits and reinterpret: see BatteryMath. Going through `uint64Value` makes this
        // give the same answer whether Core Foundation hands back a signed or unsigned number.
        guard let rawAmperage = (properties["Amperage"] as? NSNumber)?.uint64Value,
              let millivolts = (properties["Voltage"] as? NSNumber)?.intValue
        else { return nil }

        return BatteryRegistry(
            milliamps: BatteryMath.milliamps(rawAmperage: rawAmperage),
            millivolts: millivolts,
            cycleCount: (properties["CycleCount"] as? NSNumber)?.intValue
        )
    }

    private static func readAdapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else { return nil }
        return (details[kIOPSPowerAdapterWattsKey as String] as? NSNumber)?.intValue
    }
}
