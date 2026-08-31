import AppKit
import Foundation

/// Turns a dropped pasteboard into shelf items.
///
/// The decision half is pure and lives in `resolve`, so the ordering rule below is a test table
/// rather than something you can only check by dragging things around.
enum ShelfDropReader {

    /// What a drop resolved to, before any payload is written.
    enum Content: Equatable {
        case files([URL])
        case image
        case richText(plain: String)
        case text(String)
        case nothingUsable
    }

    /// Text longer than this is spilled to a file rather than held inline, so `shelf.json` stays
    /// small enough to parse instantly. Same ceiling the clipboard uses.
    static let inlineTextCeiling = 256 * 1_024

    /// **The order is the point, and it is not obvious.**
    ///
    /// A file dragged from Finder *also* offers a plain-text representation of its name, so checking
    /// text first would park the string "report.pdf" instead of the file — the feature would appear
    /// to work while doing the wrong thing on its headline use case. An image file offers TIFF too,
    /// which is why files are checked before images rather than after.
    ///
    /// `ClipboardCapturePolicy` documents the same ordering for the same reason; this is that rule
    /// applied to drops.
    static func resolve(
        fileURLs: [URL],
        hasImage: Bool,
        richTextPlain: String?,
        plainText: String?
    ) -> Content {
        if !fileURLs.isEmpty { return .files(fileURLs) }
        if hasImage { return .image }
        if let plain = richTextPlain, !plain.isEmpty { return .richText(plain: plain) }
        if let text = plainText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        return .nothingUsable
    }

    /// Reads a dropped pasteboard into the shape `resolve` decides on.
    ///
    /// `NSDraggingInfo.draggingPasteboard` is an ordinary `NSPasteboard`, so this reuses
    /// `PasteboardReader`'s file extraction rather than writing a second copy of it.
    static func content(of pasteboard: NSPasteboard) -> Content {
        let (types, source) = PasteboardReader.typesAndSource(of: pasteboard)
        let snapshot = PasteboardReader.snapshot(of: pasteboard, types: types, source: source)

        return resolve(
            fileURLs: snapshot.filePaths.map(URL.init(fileURLWithPath:)),
            hasImage: (snapshot.imageByteCount ?? 0) > 0,
            richTextPlain: (snapshot.richTextByteCount ?? 0) > 0 ? snapshot.plainText : nil,
            plainText: snapshot.plainText
        )
    }

    /// Builds the items to park, writing any payloads the store needs to own.
    ///
    /// Files dropped together share a `groupID` so a five-file drag comes back out as a unit.
    static func items(
        from pasteboard: NSPasteboard,
        store: ShelfStore,
        sourceBundleID: String? = nil
    ) -> [ShelfItem] {
        let group = UUID()

        switch content(of: pasteboard) {
        case .nothingUsable:
            return []

        case .files(let urls):
            let references = urls.compactMap { url -> ShelfItem.FileReference? in
                guard let bookmark = ActionRunner.bookmark(for: url) else { return nil }
                return ShelfItem.FileReference(bookmark: bookmark, lastKnownPath: url.path)
            }
            guard !references.isEmpty else { return [] }
            return [ShelfItem(kind: .files(references), sourceBundleID: sourceBundleID, groupID: group)]

        case .image:
            guard let data = PasteboardReader.pngData(from: pasteboard),
                  let image = NSImage(data: data),
                  let name = store.writePayload(data, extension: "png")
            else { return [] }
            return [ShelfItem(
                kind: .image(
                    fileName: name,
                    width: Int(image.size.width),
                    height: Int(image.size.height),
                    byteCount: data.count
                ),
                sourceBundleID: sourceBundleID,
                groupID: group
            )]

        case .richText(let plain):
            guard let rtf = pasteboard.data(forType: .rtf),
                  let name = store.writePayload(rtf, extension: "rtf")
            else { return textItems(plain, store: store, source: sourceBundleID, group: group) }
            return [ShelfItem(
                kind: .richText(fileName: name, plain: plain),
                sourceBundleID: sourceBundleID,
                groupID: group
            )]

        case .text(let value):
            return textItems(value, store: store, source: sourceBundleID, group: group)
        }
    }

    private static func textItems(
        _ value: String,
        store: ShelfStore,
        source: String?,
        group: UUID
    ) -> [ShelfItem] {
        guard value.utf8.count > inlineTextCeiling else {
            return [ShelfItem(kind: .text(value), sourceBundleID: source, groupID: group)]
        }
        guard let name = store.writePayload(Data(value.utf8), extension: "txt") else { return [] }
        return [ShelfItem(
            kind: .largeText(
                fileName: name,
                preview: String(value.prefix(200)),
                characterCount: value.count
            ),
            sourceBundleID: source,
            groupID: group
        )]
    }
}
