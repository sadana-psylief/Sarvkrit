import Darwin
import Foundation

/// Reads the kernel's per-core tick counters and sums them.
///
/// `host_processor_info` allocates the array it hands back in this task's VM space, and ARC knows
/// nothing about it — it must be handed to `vm_deallocate` or every sample leaks. At the default
/// two-second interval that is a few kilobytes a tick, which is invisible in a test run and
/// obvious in Activity Monitor a day later. Hence the `defer`.
enum CPUSampler {
    /// Active rather than total: a core the system has parked contributes no ticks, and counting it
    /// would make a fully-loaded Mac read as less than 100% busy.
    static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    static func readTicks() -> CPUTicks? {
        var coreCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, coreCount > 0 else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        // Rebound rather than indexed as `integer_t`: the ticks are unsigned, and read through the
        // array's signed element type they turn negative once a core passes 2^31 ticks — which on a
        // long-running Mac is days, not never.
        let loads = UnsafeRawPointer(info).bindMemory(
            to: processor_cpu_load_info.self, capacity: Int(coreCount))

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(coreCount) {
            let ticks = loads[core].cpu_ticks
            let user = UInt64(ticks.0)     // CPU_STATE_USER
            let system = UInt64(ticks.1)   // CPU_STATE_SYSTEM
            let idle = UInt64(ticks.2)     // CPU_STATE_IDLE
            let nice = UInt64(ticks.3)     // CPU_STATE_NICE
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }
}
