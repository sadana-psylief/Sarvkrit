import Foundation
import UniformTypeIdentifiers

/// Reads a file from disk into the flat `FileSnapshot` the matcher works on.
///
/// Gathering everything once, up front, is what lets `RuleMatcher` stay pure: rule evaluation
/// never touches the filesystem, so the whole condition vocabulary is testable against a struct.
enum FileInspector {
    private static let keys: Set<URLResourceKey> = [
        .nameKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey,
        .creationDateKey, .isDirectoryKey, .contentTypeKey, .tagNamesKey,
    ]

    static func snapshot(of url: URL) -> FileSnapshot? {
        // NSURL caches resource values, and URL bridges to it — so re-reading the same URL returns
        // the size and modification date from the first read. That silently breaks stability
        // detection: a file that is still growing looks unchanged and gets filed half-written,
        // which is the exact failure the check exists to prevent.
        (url as NSURL).removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let isDirectory = values.isDirectory ?? false
        let fullName = url.lastPathComponent

        return FileSnapshot(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            fileExtension: url.pathExtension,
            fullName: fullName,
            kind: isDirectory ? .folder : kind(for: values.contentType),
            size: Int64(values.fileSize ?? 0),
            // addedToDirectoryDate is the one that means "arrived here", which is what a rule
            // about downloads cares about. It isn't always available; creation date is the
            // closest honest fallback.
            dateAdded: values.addedToDirectoryDate ?? values.creationDate ?? Date(),
            dateModified: values.contentModificationDate ?? Date(),
            sourceURL: sourceURL(of: url),
            tags: values.tagNames ?? [],
            isDirectory: isDirectory
        )
    }

    static func kind(for type: UTType?) -> FileKind {
        guard let type else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .application) { return .application }
        if type.conforms(to: .archive) { return .archive }
        // Checked after the specific types: .content is broad enough to swallow images otherwise.
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) || type.conforms(to: .content) {
            return .document
        }
        return .other
    }

    /// Where a download came from, as recorded by the quarantine/where-from metadata Safari and
    /// friends attach. Absent for files that were never downloaded.
    static func sourceURL(of url: URL) -> String? {
        guard let data = extendedAttribute(named: "com.apple.metadata:kMDItemWhereFroms", at: url)
        else { return nil }
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = list as? [String]
        else { return nil }
        return entries.first { !$0.isEmpty }
    }

    static func extendedAttribute(named name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = Data(count: length)
            let read = buffer.withUnsafeMutableBytes { raw in
                getxattr(path, name, raw.baseAddress, length, 0, 0)
            }
            return read >= 0 ? buffer : nil
        }
    }

    @discardableResult
    static func setExtendedAttribute(named name: String, value: Data, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withUnsafeBytes { raw in
                setxattr(path, name, raw.baseAddress, value.count, 0, 0) == 0
            }
        }
    }
}
