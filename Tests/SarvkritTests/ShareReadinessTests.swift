import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Sarvkrit

/// "Capture something and it's instantly ready to share… no folders to dig through."
///
/// The claim has three parts and each one is a thing that can quietly not be true: the file has to
/// exist *before* the overlay offers it, the drag has to carry the type other apps accept, and the
/// clipboard has to carry a format they paste.
@MainActor
final class ShareReadinessTests: XCTestCase {

    private func store() throws -> (CaptureHistoryStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (CaptureHistoryStore(directory: directory), directory)
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        return try XCTUnwrap(context.makeImage())
    }

    func testTheFileIsOnDiskBeforeAnythingOffersItForDragging() throws {
        // The overlay's whole proposition is that the capture is *already* a file. If the PNG were
        // written when Save is clicked, the drag would have nothing behind it — which is the bug
        // `ShelfDragSource` records as a drop that "quietly did nothing".
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area,
                                           sourceRect: .zero, displayID: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
    }

    func testTheDragCarriesAFileURLAndNotAnImage() throws {
        // Finder wants `public.file-url`. An in-memory image is what silently does nothing.
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area,
                                           sourceRect: .zero, displayID: nil))

        let pasteboard = NSPasteboard(name: .init("SarvkritDragTest"))
        pasteboard.clearContents()
        // Exactly what `CaptureDragSource` hands to `NSDraggingItem`.
        pasteboard.writeObjects([store.url(for: item) as NSURL])

        XCTAssertTrue(pasteboard.types?.contains(.fileURL) ?? false,
                      "no public.file-url on the drag: \(pasteboard.types ?? [])")
        let read = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(read?.first?.lastPathComponent, item.fileName)
        XCTAssertTrue(read?.first?.isFileURL ?? false)
    }

    func testWhatIsDraggedIsAPNGAnotherAppCanOpen() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area,
                                           sourceRect: .zero, displayID: nil))
        let url = store.url(for: item)

        XCTAssertEqual(UTType(filenameExtension: url.pathExtension), .png)
        // Decoded through ImageIO rather than our own reader, which is what the receiving app does.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 200)
        XCTAssertEqual(decoded.height, 120)
    }

    func testCopyPutsAPasteableImageOnTheClipboard() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area,
                                           sourceRect: .zero, displayID: nil))

        let pasteboard = NSPasteboard(name: .init("SarvkritCopyTest"))
        pasteboard.clearContents()
        let loaded = try XCTUnwrap(NSImage(contentsOf: store.url(for: item)))
        let tiff = try XCTUnwrap(loaded.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        pasteboard.setData(png, forType: .png)

        XCTAssertTrue(pasteboard.types?.contains(.png) ?? false)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(pasteboard.data(forType: .png))))
    }

    func testAnEditedCaptureReplacesItsFileRatherThanLeavingTwo() throws {
        // "No folders to dig through" only holds if editing does not quietly multiply the files.
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area,
                                           sourceRect: .zero, displayID: nil))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }

        store.replaceImage(of: item.id, with: try image())
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(after, before, "editing left a second file behind")
    }
}
