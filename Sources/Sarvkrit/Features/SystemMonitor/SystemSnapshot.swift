import Foundation

/// One round of readings. Every field is optional because a domain the user switched off is not
/// sampled at all, and because several of them are legitimately absent on some Macs — a desktop
/// reports no battery, a machine with no matching accelerator reports no GPU utilisation.
///
/// `Equatable` throughout so the feature can skip publishing when nothing moved.
struct SystemSnapshot: Equatable {
    var cpu: CPUSample?
    var gpu: GPUSample?
    var power: PowerSample?
    var battery: BatterySample?
    var memory: MemorySample?
    var disk: DiskSample?
    var network: NetworkSample?
}

struct CPUSample: Equatable {
    /// Degrees Celsius, or `nil` where no sensor answered — an Intel Mac, which reports through
    /// the SMC rather than the HID sensor path, or a build macOS declined to hand sensors to.
    var celsius: Double?
    /// 0…100 across all cores, from the tick delta between two samples — and therefore `nil` on
    /// the very first sample, which has nothing to diff against. Reporting 0% there would claim an
    /// idle Mac rather than admitting to having no reading yet.
    var usage: Double?
    var coreCount: Int
    var loadAverage: Double?
}

struct GPUSample: Equatable {
    var usage: Double
    /// Degrees Celsius. See `CPUSample.celsius` for when this is absent.
    var celsius: Double?
}

struct MemorySample: Equatable {
    /// What macOS calls "Memory Used": app memory plus wired plus compressed.
    var used: UInt64
    /// How hard the kernel is working to find memory, which is the more useful question than how
    /// much is in use. `nil` when the kernel reports a level this build doesn't recognise.
    var pressure: MemoryPressure?
    var total: UInt64
    var swapUsed: UInt64?

    var usagePercent: Double? {
        guard total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

struct DiskSample: Equatable {
    /// Every mounted volume worth showing. The `used`/`total` below stay as they were — the boot
    /// volume — because that is what the menu bar readout and the sparkline plot.
    var volumes: [MountedVolume] = []
    /// The internal drive's own health. One reading for the machine, not one per volume: SMART
    /// belongs to a physical device. See `SMARTReader`.
    var smart: SMARTReader.Reading?
    var used: UInt64
    var total: UInt64
    var readPerSecond: Double?
    var writePerSecond: Double?

    var usagePercent: Double? {
        guard total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

struct NetworkSample: Equatable {
    var downloadPerSecond: Double?
    var uploadPerSecond: Double?
    /// Bytes since the monitor was switched on — see `SessionTotals` for what "session" means and
    /// why it is not the uptime of the Mac.
    var sessionDownloaded: UInt64 = 0
    var sessionUploaded: UInt64 = 0
}

struct BatterySample: Equatable {
    var percent: Double
    var isCharging: Bool
    /// False on desktops. Distinguishes "no battery" from "a battery at 0%".
    var isPresent: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    /// How much of its design capacity the battery still holds — System Settings' "Maximum
    /// Capacity". Absent on a desktop, and on any Mac whose registry omits the capacity keys.
    var healthPercent: Double?
    /// Degrees Celsius, from the battery's own public registry entry rather than the private
    /// sensor path the CPU and GPU temperatures need.
    var celsius: Double?
}

struct PowerSample: Equatable {
    enum Source: Equatable {
        case battery
        case adapter
    }

    var source: Source
    /// Negative while discharging, positive while charging. Nil where no amperage is reported.
    var watts: Double?
    /// The adapter's rated wattage, when one is connected.
    var adapterWatts: Int?
}


extension SystemSnapshot {
    /// The single number a metric's sparkline plots.
    ///
    /// `nil` where the reading is genuinely unavailable, which `MetricHistory` stores as a gap
    /// rather than flattening to zero. Rates are summed across both directions: one line per metric
    /// is what fits, and "how busy is the disk" is the question a sparkline this size can answer.
    func chartValue(for kind: MetricKind) -> Double? {
        switch kind {
        case .cpu:
            return cpu?.usage
        case .gpu:
            return gpu?.usage
        case .memory:
            return memory?.usagePercent
        case .disk:
            guard let disk, let read = disk.readPerSecond, let written = disk.writePerSecond
            else { return nil }
            return read + written
        case .network:
            guard let network, let down = network.downloadPerSecond,
                  let up = network.uploadPerSecond else { return nil }
            return down + up
        case .power:
            return power?.watts
        case .battery:
            guard let battery, battery.isPresent else { return nil }
            return battery.percent
        }
    }
}
