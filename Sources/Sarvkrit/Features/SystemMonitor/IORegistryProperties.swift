import Foundation
import IOKit

/// Shared plumbing for reading property dictionaries out of the IO registry.
///
/// It exists so the release discipline is written once. Every IOKit read here acquires objects ARC
/// knows nothing about — the matching iterator, each service inside it, and the copied property
/// dictionary — and the monitor performs these reads every couple of seconds for as long as the app
/// runs. A missed `IOObjectRelease` is a handle leaked per tick: invisible in a single call,
/// terminal over a day. Callers get the properties and never see the handles.
enum IORegistryProperties {

    /// Properties of the first service matching `className`, or nil if there is none.
    static func first(matching className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return properties(of: service)
    }

    /// Properties of every service matching `className`.
    ///
    /// Plural on purpose: the boot disk appears as more than one `IOBlockStorageDriver`, and the
    /// first one found reports all-zero counters. Taking `first` there would silently report a Mac
    /// that never touches its disk.
    static func all(matching className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        // The iterator is itself an IOKit object, and is the one most often forgotten.
        defer { IOObjectRelease(iterator) }

        var found: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            // Declared inside the loop body so this releases *this* iteration's service; hoisting
            // it and reassigning would release the following one instead.
            defer { IOObjectRelease(service) }
            if let properties = properties(of: service) { found.append(properties) }
        }
        return found
    }

    private static func properties(of service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        // "Create" in the name means this dictionary is ours to own, hence retained, not
        // unretained — the difference between a leak and a crash.
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }
}
