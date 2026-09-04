import AppKit
import Foundation

/// One mounted volume, as the Disks panel shows it.
struct MountedVolume: Equatable, Identifiable {
    var id: String { url.path }

    var url: URL
    var name: String
    /// "APFS", "Mac OS Extended", "ExFAT" — macOS's own words for it.
    var format: String?
    var used: UInt64
    var total: UInt64
    var isInternal: Bool
    var isEjectable: Bool

    var usagePercent: Double? {
        guard total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

/// The volumes worth showing, and only those.
///
/// All public API. `FileManager` already knows how to enumerate mounts and hand back capacity and
/// the internal/removable flags, so nothing here needs DiskArbitration or a privileged call.
///
/// The filtering is the substance. A Mac has a dozen or more mounts and most are machinery: the
/// Preboot, VM, Update and xarts volumes of the boot group, the read-only system snapshot, every
/// mounted disk image. Listing them would bury the two or three a person recognises. `skipHiddenVolumes`
/// removes most, and the browsable check removes the rest — it is the same question Finder asks
/// before putting something in its sidebar, so the panel lists what Finder lists.
enum VolumeLister {
    static func list() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsBrowsableKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }

        return urls.compactMap { url in volume(at: url, keys: keys) }
    }

    private static func volume(at url: URL, keys: [URLResourceKey]) -> MountedVolume? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        guard values.volumeIsBrowsable ?? false else { return nil }

        // `...ForImportantUsage` rather than the plain available capacity: it is what Finder shows,
        // because it counts space macOS would reclaim from purgeable files if something needed it.
        // The plain figure reads gigabytes lower and leaves Sarvkrit disagreeing with Get Info.
        guard let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }

        let totalBytes = UInt64(total)
        let availableBytes = UInt64(max(0, available))

        return MountedVolume(
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            format: values.volumeLocalizedFormatDescription,
            // Clamped: available can exceed total once purgeable space is counted in, and an
            // unsigned subtraction that goes negative traps rather than reading oddly.
            used: totalBytes > availableBytes ? totalBytes - availableBytes : 0,
            total: totalBytes,
            isInternal: values.volumeIsInternal ?? false,
            // Ejectable and removable are not the same question — a USB stick is both, an external
            // SSD is ejectable but not removable — and either one means there is something to
            // offer an Eject button for.
            isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false))
    }

    /// Unmounts and ejects, reporting the reason it could not.
    ///
    /// "The disk is in use by another application" is the ordinary outcome, not an edge case, and
    /// the panel has nowhere to put a dialog — a `MenuBarExtra` panel dismisses as focus moves. So
    /// the error comes back as a string for the card to show inline.
    @MainActor
    static func eject(_ volume: MountedVolume) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            return nil
        } catch {
            return (error as NSError).localizedRecoverySuggestion ?? error.localizedDescription
        }
    }
}
