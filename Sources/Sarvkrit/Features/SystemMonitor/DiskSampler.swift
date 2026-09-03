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
