import Foundation

struct DiskCapacity: Equatable {
    var used: UInt64
    var total: UInt64
}

/// Boot-volume capacity, through the same URL resource keys Finder reports from.
///
/// `volumeAvailableCapacityForImportantUsage` rather than the plain available key: on APFS a large
/// share of "free" space is purgeable — local snapshots, caches — and the plain key reports it as
/// used, so Sarvkrit and Finder would disagree about the same disk by tens of gigabytes.
enum DiskSampler {
    static func readCapacity() -> DiskCapacity? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }

        let totalBytes = UInt64(total)
        // Because "important usage" counts purgeable space as available, it can in principle come
        // back above the total. Clamping keeps `used` from underflowing.
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        return DiskCapacity(
            used: totalBytes > available ? totalBytes - available : 0,
            total: totalBytes
        )
    }
}

/// Cumulative bytes moved to and from the boot disk.
struct DiskThroughput: Equatable {
    var read: UInt64
    var written: UInt64
}

extension DiskSampler {
    /// Summed across every `IOBlockStorageDriver`, not taken from the first.
    ///
    /// The boot disk presents more than one driver and the first one found reports all-zero
    /// counters, so reading `first` here reports a Mac that never touches its disk — a bug that
    /// looks exactly like an idle system.
    static func readThroughput() -> DiskThroughput? {
        let drivers = IORegistryProperties.all(matching: "IOBlockStorageDriver")
        guard !drivers.isEmpty else { return nil }

        var read: UInt64 = 0
        var written: UInt64 = 0
        for properties in drivers {
            guard let statistics = properties["Statistics"] as? [String: Any] else { continue }
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return DiskThroughput(read: read, written: written)
    }
}
