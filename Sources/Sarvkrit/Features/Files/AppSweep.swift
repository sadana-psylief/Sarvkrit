import AppKit
import Foundation

/// Where an app's leftovers live, and how to recognise them.
///
/// Matching is on **bundle identifier only**. Matching on app name is how tools in this category
/// delete the wrong thing — "Mail", "Notes" and "Music" are not distinctive, and a support folder
/// named after a common word belongs to whoever claimed it first.
enum AppLeftovers {
    /// One installed app, remembered so its identity survives deletion.
    ///
    /// This inventory is the whole trick: once an app bundle is gone you cannot read its
    /// `Info.plist`, so the bundle ID has to have been recorded while it was still there.
    struct InstalledApp: Codable, Equatable, Identifiable {
        var bundleID: String
        var name: String
        var path: String
        var id: String { bundleID }
    }

    struct Candidate: Equatable, Identifiable {
        var url: URL
        var size: Int64
        var id: String { url.path }
    }

    /// Directories searched for leftovers, relative to ~/Library.
    static let searchRoots = [
        "Application Support",
        "Caches",
        "Preferences",
        "Containers",
        "Saved Application State",
        "Logs",
        "HTTPStorages",
        "WebKit",
    ]

    /// Filenames a leftover may take for a given bundle ID. Exact stems only — a prefix match
    /// would let `com.example.app` claim `com.example.apple`.
    static func leftoverNames(for bundleID: String) -> Set<String> {
        [
            bundleID,
            "\(bundleID).plist",
            "\(bundleID).savedState",
            "\(bundleID).binarycookies",
        ]
    }

    /// Whether a directory entry belongs to this bundle ID. Pure, so the matching rule that decides
    /// what gets deleted is testable without a filesystem.
    static func isLeftover(name: String, bundleID: String) -> Bool {
        leftoverNames(for: bundleID).contains(name)
    }

    /// Searches for leftovers. Unreadable directories are **skipped, never treated as empty** —
    /// a TCC-restricted folder means "unknown", and reporting "no leftovers" would be a lie.
    static func findCandidates(
        for bundleID: String,
        libraryURL: URL,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        var found: [Candidate] = []

        for root in searchRoots {
            let directory = libraryURL.appendingPathComponent(root)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: []
            ) else { continue }

            for entry in entries where isLeftover(name: entry.lastPathComponent, bundleID: bundleID) {
                found.append(Candidate(url: entry, size: size(of: entry, fileManager: fileManager)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return 0
        }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }

        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Which apps in the remembered inventory are no longer on disk.
    ///
    /// Pure so the delete-vs-update distinction — the thing that decides whether someone's
    /// preferences survive an app update — is table-tested.
    static func removedApps(
        inventory: [InstalledApp],
        stillPresentPaths: Set<String>,
        stillRegisteredBundleIDs: Set<String>
    ) -> [InstalledApp] {
        inventory.filter { app in
            guard !stillPresentPaths.contains(app.path) else { return false }
            // An update is a delete followed by a replace. If macOS can still find the bundle ID
            // anywhere, the app moved or was upgraded — it was not uninstalled, and sweeping its
            // support files mid-update is the classic false positive in this category.
            return !stillRegisteredBundleIDs.contains(app.bundleID)
        }
    }
}
