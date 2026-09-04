import Foundation
import IOKit

/// What the drive says about its own health.
///
/// Pure, so the one decision here — which readings mean "failing" — is a test table rather than
/// something reproducible only on a dying SSD.
enum SMARTStatus: Equatable {
    case ok
    case failing
    /// Not that the drive is unhealthy: that nothing answered. Most external USB enclosures do not
    /// pass SMART through at all. The panel shows no badge rather than an empty or grey one, since
    /// a badge saying nothing is worse than no badge.
    case unavailable

    /// NVMe's Critical Warning byte is a bit field, and **any** bit set is a fault: spare capacity
    /// below threshold, temperature past its limit, media errors, read-only fallback, failed
    /// volatile-memory backup. Testing for a specific value rather than for zero is how a drive
    /// that is overheating gets reported as fine.
    static func from(criticalWarning: UInt8) -> SMARTStatus {
        criticalWarning == 0 ? .ok : .failing
    }
}

/// The internal drive's SMART data, through NVMe's own interface.
///
/// **Scope, stated plainly:** this reports the *internal* NVMe drive. SMART belongs to a physical
/// device, not to a volume, and Sarvkrit does not map mounted volumes back to their devices — so
/// the badge appears on internal volumes and never on external ones. That is not much of a loss in
/// practice: USB and Thunderbolt enclosures overwhelmingly do not pass SMART through, so the honest
/// answer for most external drives would be "unavailable" anyway.
///
/// Reached through `IOCreatePlugInInterfaceForService` and a COM-style vtable, which is the only
/// interface macOS offers for this. Every step is checked, and any failure is `.unavailable`.
enum SMARTReader {
    struct Reading: Equatable {
        var status: SMARTStatus
        /// The drive's own estimate of how much of its rated write endurance is gone. Can exceed
        /// 100 on a well-used drive, and NVMe says so explicitly, so it is not clamped.
        var percentageUsed: Int?
    }

    // The plugin type, the interface and the plug-in interface, as raw UUID bytes. These are not
    // exposed as constants by any public header.
    private static let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
        0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    private static let interfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
        0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    /// The prefix of `IONVMeSMARTInterface`, up to and including the one function called.
    ///
    /// Declared rather than imported because no public header describes it. Only the leading
    /// members are modelled: layout is positional, so the calls after `SMARTReadData` can be left
    /// out, but nothing before it may be reordered or omitted.
    private struct IONVMeSMARTInterface {
        var _reserved: UnsafeMutableRawPointer?
        var queryInterface: @convention(c) (
            UnsafeMutableRawPointer?, REFIID, UnsafeMutablePointer<LPVOID?>?) -> HRESULT
        var addRef: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var release: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var version: UInt16
        var revision: UInt16
        var smartReadData: @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
    }

    /// Offsets into NVMe's 512-byte SMART / Health Information log page.
    private enum LogPage {
        static let size = 512
        static let criticalWarning = 0
        static let percentageUsed = 5
    }

    /// **Call from a background queue.** Opens a user client and talks to the drive.
    static func readInternal() -> Reading {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator)
            == KERN_SUCCESS else { return Reading(status: .unavailable, percentageUsed: nil) }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard isNVMeSMARTCapable(service), let reading = read(service: service) else { continue }
            return reading
        }
        return Reading(status: .unavailable, percentageUsed: nil)
    }

    private static func isNVMeSMARTCapable(_ service: io_object_t) -> Bool {
        (IORegistryEntryCreateCFProperty(service, "NVMe SMART Capable" as CFString, nil, 0)?
            .takeRetainedValue() as? Bool) == true
    }

    private static func read(service: io_object_t) -> Reading? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(
            service, userClientTypeID, plugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
            let plugin else { return nil }
        defer { IODestroyPlugInInterface(plugin) }

        var raw: LPVOID?
        guard plugin.pointee?.pointee.QueryInterface(
            plugin, CFUUIDGetUUIDBytes(interfaceID), &raw) == S_OK, let raw else { return nil }

        let interface = raw.assumingMemoryBound(to: UnsafeMutablePointer<IONVMeSMARTInterface>?.self)
        defer { _ = interface.pointee?.pointee.release(interface) }

        var page = [UInt8](repeating: 0, count: LogPage.size)
        let result = page.withUnsafeMutableBytes { buffer in
            interface.pointee?.pointee.smartReadData(interface, buffer.baseAddress) ?? kIOReturnError
        }
        guard result == KERN_SUCCESS else { return nil }

        return Reading(
            status: SMARTStatus.from(criticalWarning: page[LogPage.criticalWarning]),
            percentageUsed: Int(page[LogPage.percentageUsed]))
    }
}
