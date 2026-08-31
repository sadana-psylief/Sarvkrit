import Foundation

/// One thing parked on the shelf.
///
/// The `Kind` cases deliberately mirror `ClipboardItem.Kind`, so `PasteboardReader` and
/// `Paster` can be reused for reading drops and writing drags back out. It is **not** the same type:
/// `ClipboardItem` carries `copyCount`, `firstCopiedAt`, pinning and a `dedupeKey`, all of which
/// encode "re-copying the same thing" semantics that are wrong for a shelf — parking the same file
/// twice is a legitimate thing to do. `ClipboardItem` also has a hand-written decoder that is
/// load-bearing for existing users' history, and adding fields to it risks that migration.
struct ShelfItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: Kind
    var addedAt: Date = Date()
    /// Which app it came from, for the row's icon.
    var sourceBundleID: String?
    /// Items dropped together stay together — "groups compatible drops" — so a five-file drag is
    /// one row you can take back out as a unit rather than five loose ones.
    var groupID: UUID?

    enum Kind: Codable, Equatable {
        case text(String)
        /// Text past the inline ceiling, spilled to a file beside the index.
        case largeText(fileName: String, preview: String, characterCount: Int)
        case richText(fileName: String, plain: String)
        case image(fileName: String, width: Int, height: Int, byteCount: Int)
        /// **References, not copies.** A shelf points at the user's files; it does not take custody
        /// of them. Stored as bookmarks rather than paths so a file that gets renamed or moved
        /// between sessions still resolves — `Rule` states the same rule for watch folders: "a
        /// bookmark rather than a path: folders get renamed and moved, and a stale path fails
        /// silently."
        case files([FileReference])
    }

    /// A parked file: the bookmark that survives a move, plus the path it had when parked so the row
    /// has something to show even if the bookmark no longer resolves.
    struct FileReference: Codable, Equatable {
        var bookmark: Data
        var lastKnownPath: String

        var displayName: String { (lastKnownPath as NSString).lastPathComponent }
    }

    /// What the row shows.
    var displayText: String {
        switch kind {
        case .text(let value): return value
        case .largeText(_, let preview, _): return preview
        case .richText(_, let plain): return plain
        case .image: return "Image"
        case .files(let references):
            guard let first = references.first else { return "No files" }
            return references.count == 1
                ? first.displayName
                : "\(first.displayName) and \(references.count - 1) more"
        }
    }

    /// Backing files this item owns, which the store deletes when the item goes.
    ///
    /// **`.files` returns an empty array, and that is the whole point.** The app never owns a file it
    /// merely points at, so removing an item from the shelf can never delete the user's document.
    /// `ClipboardItem` draws the same line for the same reason.
    var backingFileNames: [String] {
        switch kind {
        case .largeText(let name, _, _), .richText(let name, _), .image(let name, _, _, _):
            return [name]
        case .text, .files:
            return []
        }
    }

    var isFileReference: Bool {
        if case .files = kind { return true }
        return false
    }
}
