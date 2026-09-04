import Darwin
import Foundation

/// How hard macOS is having to work to find memory.
///
/// Not the same question as "how much memory is used", and the more useful one. A Mac at 90% used
/// with normal pressure is doing exactly what it should — macOS fills unused RAM with cache and
/// gives it back on demand — while one at 60% under warning pressure is compressing and swapping.
/// The percentage alone routinely alarms people about the first case and says nothing about the
/// second.
///
/// The raw values are the kernel's own, and they are a bit field rather than a sequence: 1, 2, 4.
/// Anything else is a level this build has never heard of, which resolves to `nil` rather than
/// being rounded to the nearest one we do know — guessing here would mean reporting "normal" for a
/// state the kernel invented to mean something worse.
enum MemoryPressure: Equatable {
    case normal
    case warning
    case critical

    /// Pure, so the mapping is a test table rather than something only observable on a Mac that
    /// happens to be under memory pressure at the time.
    static func level(raw: Int32) -> MemoryPressure? {
        switch raw {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    static func read() -> MemoryPressure? {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0
        else { return nil }
        return level(raw: raw)
    }
}
