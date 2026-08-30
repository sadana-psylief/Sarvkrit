import Foundation

/// One entry in the clipboard history.
///
/// Payloads that could be large — images, and text past a ceiling — live as files beside the index
/// rather than inside it, so `clipboard.json` stays small enough to parse instantly at launch.
struct ClipboardItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: Kind
    /// When this was most recently copied. Moves forward on every repeat copy.
    var createdAt: Date = Date()
    /// When it was *first* seen. Fixed for the life of the entry.
    var firstCopiedAt: Date = Date()
    /// How many times this exact thing has been copied — drives the "number of copies" sort.
    var copyCount: Int = 1
    var sourceBundleID: String?
    var isPinned: Bool = false

    init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = Date(),
        firstCopiedAt: Date? = nil,
        copyCount: Int = 1,
        sourceBundleID: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.firstCopiedAt = firstCopiedAt ?? createdAt
        self.copyCount = copyCount
        self.sourceBundleID = sourceBundleID
        self.isPinned = isPinned
    }

    /// Hand-written **so that history saved before these fields existed still decodes**.
    ///
    /// The synthesized decoder requires every non-optional property to be present, and
    /// `ClipboardStore.load()` responds to a decode failure by emptying the history — so shipping
    /// the synthesized version would have silently wiped every existing user's clipboard on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        // Absent in pre-migration files: an old entry has been seen at least once, and the only
        // honest "first copied" we have is when we last saw it.
        firstCopiedAt = try container.decodeIfPresent(Date.self, forKey: .firstCopiedAt) ?? createdAt
        copyCount = try container.decodeIfPresent(Int.self, forKey: .copyCount) ?? 1
    }

    enum Kind: Codable, Equatable {
        /// Short text, held inline.
        case text(String)
        /// Text past the inline ceiling, spilled to `fileName` beside the index.
        case largeText(fileName: String, preview: String, characterCount: Int)
        /// Rich text. `plain` is kept alongside so "paste as plain text" needs no conversion.
        case richText(fileName: String, plain: String)
        case image(fileName: String, width: Int, height: Int, byteCount: Int)
        /// Paths, not bytes — copying a file records where it is, exactly as the clipboard does.
        case files([String])
    }

    /// What the picker shows in a row, and what search matches against.
    var searchableText: String {
        switch kind {
        case .text(let value): return value
        case .largeText(_, let preview, _): return preview
        case .richText(_, let plain): return plain
        case .image: return "Image"
        case .files(let paths): return paths.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        }
    }

    /// Backing files this entry owns. The store deletes these when the entry goes — see
    /// `ClipboardStore`, which is the only thing allowed to touch them.
    var backingFileNames: [String] {
        switch kind {
        case .largeText(let name, _, _), .richText(let name, _), .image(let name, _, _, _):
            return [name]
        case .text, .files:
            return []
        }
    }

    /// Identity for de-duplication: re-copying the same thing should move the existing entry to the
    /// top rather than pile up. Deliberately ignores `id`, `createdAt` and pin state.
    var dedupeKey: String {
        switch kind {
        case .text(let value): return "text:\(value)"
        case .largeText(_, let preview, let count): return "large:\(count):\(preview)"
        case .richText(_, let plain): return "rich:\(plain)"
        // Two screenshots of different things can share dimensions, so size is part of the key.
        case .image(_, let w, let h, let bytes): return "image:\(w)x\(h):\(bytes)"
        case .files(let paths): return "files:\(paths.sorted().joined(separator: "|"))"
        }
    }

    var isFileReference: Bool {
        if case .files = kind { return true }
        return false
    }

    /// File entries go stale when the underlying file is moved or deleted. The picker greys these
    /// out rather than offering a paste that would quietly do nothing.
    func isResolvable(fileManager: FileManager = .default) -> Bool {
        guard case .files(let paths) = kind else { return true }
        return paths.allSatisfy { fileManager.fileExists(atPath: $0) }
    }
}
