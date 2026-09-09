import Foundation

/// The recordings already on disk.
///
/// **A recording was saved correctly and then unreachable.** `project.json` is written into the
/// bundle on every edit and flushed again as the window closes, so nothing was ever lost — but the
/// only caller of `StudioEditorController.open` was `stopRecording`, so the only way back into a
/// take was to have never closed it.
///
/// No index, no database. The bundles all live in one directory and each carries its own manifest,
/// so the directory *is* the list — which also means a recording moved, renamed or deleted in the
/// Finder needs nothing kept in step.
enum RecordingLibrary {

    struct Entry: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        /// The file's name without its extension, which is what the Finder shows.
        let name: String
        let modified: Date
        /// Nil when the manifest could not be read — there is nothing to open, but there is still
        /// something taking up disk space.
        let duration: TimeInterval?
        let hasCamera: Bool
        /// The app died inside this recording. Written faithfully all along and read by nothing.
        let needsRecovery: Bool

        var canOpen: Bool { duration != nil }

        var bundle: RecordingBundle { RecordingBundle(root: url) }

        var lengthDescription: String { Self.lengthDescription(for: duration) }

        /// `0:09`, `1:15`, `1:00:01`. Hours only when there are some.
        static func lengthDescription(for duration: TimeInterval?) -> String {
            guard let duration, duration.isFinite, duration >= 0 else { return "—" }
            let total = Int(duration.rounded())
            let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds)
        }
    }

    static func entries(in directory: URL = RecordingBundle.defaultDirectory()) -> [Entry] {
        // A directory that has never held a recording is a new install, not an error.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        return contents
            .filter { $0.pathExtension == RecordingBundle.fileExtension }
            .map(entry(for:))
            // Newest first: the recording somebody wants back is almost always the last one.
            .sorted { $0.modified > $1.modified }
    }

    static func entry(for url: URL) -> Entry {
        let manifest = try? RecordingBundle(root: url).readManifest()
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        return Entry(url: url,
                     name: url.deletingPathExtension().lastPathComponent,
                     modified: modified,
                     duration: manifest?.duration,
                     hasCamera: manifest?.hasCamera ?? false,
                     needsRecovery: manifest?.needsRecovery ?? false)
    }
}
