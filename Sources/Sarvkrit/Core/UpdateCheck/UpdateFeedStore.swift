import Foundation
import os

/// Reads what the launchd update check left on disk. Nothing here touches the network — that is
/// the whole point of the design, and the reason this is a reader and not a client.
///
/// The directory is injectable so tests never touch the real one, matching `RuleStore`.
final class UpdateFeedStore {
    /// A successful check. `checkedAt` is the file's modification time rather than anything the
    /// script writes into it, so it cannot drift out of agreement with the file it describes.
    struct Snapshot: Equatable {
        let release: LatestRelease
        let checkedAt: Date
    }

    static let feedFileName = "latest-release.json"
    static let failureMarkerName = "update-check-failed"

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "UpdateCheck")
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? Self.defaultDirectory
        self.fileManager = fileManager
    }

    /// Must agree with the path hardcoded in `check-for-update.sh`. A test pins the two together,
    /// because if they ever diverge the feature does nothing at all and says nothing about why.
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sarvkrit", isDirectory: true)
    }

    private var feedURL: URL { directory.appendingPathComponent(Self.feedFileName) }
    private var markerURL: URL { directory.appendingPathComponent(Self.failureMarkerName) }

    func read() -> Snapshot? {
        guard let data = try? Data(contentsOf: feedURL) else { return nil }
        do {
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)
            return Snapshot(release: release, checkedAt: modificationDate(of: feedURL) ?? .distantPast)
        } catch {
            // Keep the file rather than deleting it: it is evidence about what GitHub actually
            // returned, and the next run of the job replaces it anyway.
            log.error("latest-release.json could not be decoded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// When the job last tried and failed. Zero-byte marker, so only its mtime carries meaning.
    ///
    /// This is what separates "tried and couldn't reach GitHub" from "never ran at all" — and the
    /// second means something is broken (the job isn't registered, or the script lost its
    /// executable bit), which is worth saying differently to the user.
    var lastFailureAt: Date? { modificationDate(of: markerURL) }

    private func modificationDate(of url: URL) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
