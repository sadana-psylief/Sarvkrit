import Foundation

/// A file's attributes, gathered once and then matched against many conditions.
///
/// Snapshotting rather than querying lazily keeps rule evaluation pure and testable: the whole
/// condition vocabulary can be exercised against a struct, with no disk and no clock.
struct FileSnapshot: Equatable {
    var url: URL
    /// Filename without its extension.
    var name: String
    var fileExtension: String
    var fullName: String
    var kind: FileKind
    var size: Int64
    var dateAdded: Date
    var dateModified: Date
    /// Where a download came from, if macOS recorded it.
    var sourceURL: String?
    var tags: [String]
    var isDirectory: Bool
}

/// Coarse buckets, deliberately not Hazel's full UTI tree — these are the ones people actually
/// write rules against.
enum FileKind: String, Codable, CaseIterable {
    case image, video, audio, document, archive, application, folder, other

    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .archive: return "Archive"
        case .application: return "Application"
        case .folder: return "Folder"
        case .other: return "Other"
        }
    }
}

/// What a condition looks at.
enum Attribute: String, Codable, CaseIterable {
    case name, fileExtension, fullName, kind, size, dateAdded, dateModified, sourceURL, tags

    var title: String {
        switch self {
        case .name: return "Name"
        case .fileExtension: return "Extension"
        case .fullName: return "Full Name"
        case .kind: return "Kind"
        case .size: return "Size"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .sourceURL: return "Source URL"
        case .tags: return "Tags"
        }
    }
}

enum ComparisonOperator: String, Codable, CaseIterable {
    case isExactly, isNot, contains, doesNotContain, beginsWith, endsWith, matchesRegex
    case isBefore, isAfter, isInLastDays
    case isGreaterThan, isLessThan
}

/// The value a condition compares against. Typed rather than stringly, so the editor can present
/// the right control and the engine can't misinterpret "10" as a date.
enum ConditionValue: Codable, Equatable {
    case text(String)
    case number(Int64)
    case date(Date)
    case days(Int)
    case kind(FileKind)
}

struct Condition: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var attribute: Attribute
    var comparison: ComparisonOperator
    var value: ConditionValue
}

enum MatchMode: String, Codable {
    case all, any
}

/// What happens to a file that matches.
enum Action: Codable, Equatable, Identifiable {
    case move(destinationBookmark: Data)
    case copy(destinationBookmark: Data)
    case rename(pattern: String)
    case sortIntoSubfolder(pattern: String)
    case addTag(String)
    case setColorLabel(ColorLabel)
    case moveToTrash
    case notify(message: String)

    var id: String {
        switch self {
        case .move: return "move"
        case .copy: return "copy"
        case .rename: return "rename"
        case .sortIntoSubfolder: return "sortIntoSubfolder"
        case .addTag: return "addTag"
        case .setColorLabel: return "setColorLabel"
        case .moveToTrash: return "moveToTrash"
        case .notify: return "notify"
        }
    }

    /// Actions that relocate or remove the file end the chain — anything after them would be
    /// operating on a path that no longer exists.
    var isTerminal: Bool {
        switch self {
        case .move, .moveToTrash, .sortIntoSubfolder: return true
        case .copy, .rename, .addTag, .setColorLabel, .notify: return false
        }
    }
}

enum ColorLabel: Int, Codable, CaseIterable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
}

/// One rule: conditions that select files, actions applied to them.
///
/// Rules are evaluated in array order and **the first match wins**, which is Hazel's model. That
/// makes ordering semantic, not cosmetic — the editor must let the user reorder.
struct Rule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isEnabled: Bool = true
    /// A bookmark rather than a path: folders get renamed and moved, and a stale path fails silently.
    var folderBookmark: Data?
    var matchMode: MatchMode = .all
    var conditions: [Condition] = []
    var actions: [Action] = []
}
