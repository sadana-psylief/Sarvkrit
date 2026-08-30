import Foundation

/// What the user has told the clipboard to keep.
struct ClipboardSettings: Equatable {
    var storeText = true
    var storeImages = true
    var storeFiles = true
    /// `0` means no limit set.
    var maxItemSizeMB = 0
    var historyLimit = 200
    var pasteImmediately = true
    var ignoredBundleIDs: Set<String> = []

    // Display
    var sortMode: ClipboardSortMode = .lastCopy
    var searchMode: ClipboardSearch.Mode = .exact
    var pinnedPosition: PinnedPosition = .top
    var imageRowHeight = 40
    var previewDelayMilliseconds = 1_500
    var showAppIcons = true
    var highlightMatches = true

    var maxItemSizeBytes: Int? {
        maxItemSizeMB > 0 ? maxItemSizeMB * 1_048_576 : nil
    }
}

/// Turns a pasteboard snapshot into a decision about what — if anything — to record.
///
/// Pure, so the rules about size limits and folders are a table of cases rather than something
/// buried in a monitor callback.
enum ClipboardCapturePolicy {

    /// What was found on the pasteboard, already read.
    struct Snapshot: Equatable {
        var types: [String] = []
        var filePaths: [String] = []
        var directoryPaths: Set<String> = []
        var imageByteCount: Int?
        var imageWidth: Int = 0
        var imageHeight: Int = 0
        var richTextByteCount: Int?
        var plainText: String?
        var declaredSource: String?
    }

    enum Outcome: Equatable {
        case files([String])
        case image(byteCount: Int, width: Int, height: Int)
        case richText(plain: String)
        case text(String)
        case skip(Reason)

        enum Reason: Equatable {
            case kindDisabled
            case tooLarge
            case containsFolder
            case empty
        }
    }

    /// Resolution order is **files → image → richText → text**, and the order matters more than it
    /// looks. A Finder file copy also offers a plain-text representation of the filename, so
    /// checking text first would record the string "report.pdf" instead of the file — the feature
    /// would appear to work while doing the wrong thing on its headline use case.
    static func outcome(for snapshot: Snapshot, settings: ClipboardSettings) -> Outcome {
        if !snapshot.filePaths.isEmpty {
            guard settings.storeFiles else { return .skip(.kindDisabled) }
            // The user's rule: with no size limit set, keep individual files only. A folder can
            // stand for an unbounded amount of data, so it needs a deliberate opt-in.
            if settings.maxItemSizeBytes == nil, !snapshot.directoryPaths.isEmpty {
                return .skip(.containsFolder)
            }
            return .files(snapshot.filePaths)
        }

        if let bytes = snapshot.imageByteCount {
            guard settings.storeImages else { return .skip(.kindDisabled) }
            if let limit = settings.maxItemSizeBytes, bytes > limit { return .skip(.tooLarge) }
            return .image(byteCount: bytes, width: snapshot.imageWidth, height: snapshot.imageHeight)
        }

        if let rtfBytes = snapshot.richTextByteCount, let plain = snapshot.plainText, !plain.isEmpty {
            guard settings.storeText else { return .skip(.kindDisabled) }
            if let limit = settings.maxItemSizeBytes, rtfBytes > limit { return .skip(.tooLarge) }
            return .richText(plain: plain)
        }

        if let text = snapshot.plainText, !text.isEmpty {
            guard settings.storeText else { return .skip(.kindDisabled) }
            if let limit = settings.maxItemSizeBytes, text.utf8.count > limit { return .skip(.tooLarge) }
            return .text(text)
        }

        return .skip(.empty)
    }

    /// Text longer than this is spilled to a file instead of living in the index. Independent of
    /// the user's size limit: even with no limit set, a multi-megabyte paste must not end up
    /// inside `clipboard.json`, where it would slow every launch.
    static let inlineTextCeiling = 256 * 1_024

    static func shouldSpillToFile(_ text: String) -> Bool {
        text.utf8.count > inlineTextCeiling
    }
}
