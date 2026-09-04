import Darwin
import Foundation

/// Memory as macOS itself reports it.
///
/// "Used" here is Activity Monitor's definition — app memory plus wired plus compressed — not
/// "everything that isn't free". The naive version counts the file cache as used and reports a
/// healthy Mac at 95%, which is alarming and wrong; macOS deliberately fills unused RAM with cache
/// and gives it back on demand.
///
/// Total comes from `physicalMemory` rather than from summing page counts, so it matches the
/// figure on the About This Mac window exactly.
enum MemorySampler {
    static func read() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        // Purgeable pages are counted inside `internal_page_count` but are reclaimable, so macOS
        // excludes them. Subtracting on UInt32 would trap if the kernel ever reported purgeable
        // above internal, so the comparison is explicit.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appMemory = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        return MemorySample(
            used: appMemory + wired + compressed,
            pressure: MemoryPressure.read(),
            total: ProcessInfo.processInfo.physicalMemory,
            swapUsed: readSwapUsed()
        )
    }

    /// Swap is a separate sysctl; absent on a Mac that has never swapped, which is not an error.
    private static func readSwapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }
}
