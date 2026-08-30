import AppKit
import Foundation

/// Reads `NSPasteboard` into the flat snapshot `ClipboardCapturePolicy` decides on.
///
/// Kept separate so the policy never touches AppKit and stays testable, and so the type list is
/// gathered *before* any content is read — the privacy filter must be able to refuse a copy without
/// the password ever entering this process's memory.
enum PasteboardReader {

    /// Just the type list and declared source. Cheap, and enough for the privacy decision.
    static func typesAndSource(of pasteboard: NSPasteboard) -> (types: [String], source: String?) {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let source = pasteboard.string(
            forType: NSPasteboard.PasteboardType(ClipboardPrivacyFilter.sourceType))
        return (types, source)
    }

    /// Reads the content. Only called once the privacy filter has said yes.
    static func snapshot(of pasteboard: NSPasteboard, types: [String], source: String?) -> ClipboardCapturePolicy.Snapshot {
        var snapshot = ClipboardCapturePolicy.Snapshot(types: types, declaredSource: source)

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            let fileURLs = urls.filter(\.isFileURL)
            snapshot.filePaths = fileURLs.map(\.path)
            snapshot.directoryPaths = Set(
                fileURLs.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }.map(\.path)
            )
        }

        if snapshot.filePaths.isEmpty,
           let tiff = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
           let image = NSImage(data: tiff) {
            snapshot.imageByteCount = tiff.count
            snapshot.imageWidth = Int(image.size.width)
            snapshot.imageHeight = Int(image.size.height)
        }

        if let rtf = pasteboard.data(forType: .rtf) {
            snapshot.richTextByteCount = rtf.count
        }
        snapshot.plainText = pasteboard.string(forType: .string)

        return snapshot
    }

    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            return nil
        }
        if pasteboard.data(forType: .png) != nil { return data }
        // Normalise TIFF to PNG so history files are a predictable size and format.
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
