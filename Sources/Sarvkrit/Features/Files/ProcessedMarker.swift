import Foundation

/// Remembers which rule last acted on a file, so rules don't loop.
///
/// The failure this prevents: a rule whose action moves a file into a *watched* subfolder. The move
/// fires a filesystem event, the file matches the same rule again, and it moves again — forever.
///
/// The record lives in an extended attribute rather than a sidecar index or the Finder comment.
/// An xattr is invisible to the user, travels with the file across same-volume moves, and can't
/// clobber anything they wrote themselves. (An inode-keyed index goes stale when inodes are reused;
/// the Finder comment is user-visible and theirs, not ours.)
enum ProcessedMarker {
    static let attributeName = "\(AppIdentity.bundleID).lastMatched"

    struct Record: Codable, Equatable {
        var ruleID: UUID
        var date: Date
    }

    /// The decision, split out and pure so the loop-prevention rule is testable without a disk.
    ///
    /// Skips when *this* rule already handled the file and the file hasn't changed since. A file
    /// modified after its last match is legitimately new work; a different rule is always allowed
    /// to act, since chaining rules is a real thing people do.
    static func shouldSkip(lastMatch: Record?, ruleID: UUID, fileModified: Date) -> Bool {
        guard let lastMatch, lastMatch.ruleID == ruleID else { return false }
        return fileModified <= lastMatch.date
    }

    static func read(at url: URL) -> Record? {
        guard let data = FileInspector.extendedAttribute(named: attributeName, at: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    @discardableResult
    static func write(_ record: Record, at url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return FileInspector.setExtendedAttribute(named: attributeName, value: data, at: url)
    }
}

/// Refuses to act on a file that is still being written.
///
/// A download in progress looks like a perfectly ordinary file; filing it mid-transfer leaves the
/// user with a truncated file in the wrong place. A file counts as settled once its size and
/// modification date are unchanged since the previous look — the same approach Hazel takes.
struct FileStabilityTracker {
    struct Sample: Equatable {
        var size: Int64
        var modified: Date
    }

    private var samples: [URL: Sample] = [:]

    /// First sight of a file is never stable: there is nothing to compare against yet, so it waits
    /// for the next event. Deliberately cautious — a late file is recoverable, a half-copied one
    /// often isn't.
    mutating func isStable(_ url: URL, sample: Sample) -> Bool {
        defer { samples[url] = sample }
        guard let previous = samples[url] else { return false }
        return previous == sample
    }

    mutating func forget(_ url: URL) {
        samples.removeValue(forKey: url)
    }

    static func sample(of snapshot: FileSnapshot) -> Sample {
        Sample(size: snapshot.size, modified: snapshot.dateModified)
    }
}
