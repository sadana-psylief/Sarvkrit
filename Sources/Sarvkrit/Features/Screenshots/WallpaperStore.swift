import Combine
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The images a user has added as backgrounds.
///
/// **A copy in our own folder, keyed by filename, not a bookmark to wherever they picked it from.**
/// `CaptureBackground.Fill.image` has always carried a filename and said why in a comment — "a
/// filename, never a path that can move" — describing a store that was never built. A document is
/// saved, mailed, opened on another Mac and reopened next year; a path into somebody's Downloads
/// folder is a background that works until it doesn't, and the failure is silent because a missing
/// fill just paints something else.
///
/// Built like `BackgroundPresetStore`: injectable directory, and an unreadable file is left alone
/// rather than replaced.
@MainActor
final class WallpaperStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")
    private let directory: URL
    private var cache: [String: CGImage] = [:]

    /// Filenames, newest last.
    @Published private(set) var fileNames: [String] = []

    /// One store for the whole app, matching how the editor windows share their preset store.
    /// Wallpapers are files on disk; two stores would be two caches of the same folder.
    static let shared = WallpaperStore()

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
        reload()
    }

    static var defaultDirectory: URL {
        BackgroundPresetStore.defaultDirectory.appendingPathComponent("Wallpapers",
                                                                     isDirectory: true)
    }

    /// The types the import panel should offer, and the only ones `add` accepts.
    static let readableTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp]

    private func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        fileNames = contents.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Copies an image in and returns the name to store on the document, or nil if it is not one.
    ///
    /// The name is made unique rather than overwriting: two files called `bg.png` from different
    /// folders are two different backgrounds, and a document already pointing at the first must
    /// not silently acquire the second.
    @discardableResult
    func add(contentsOf url: URL) -> String? {
        guard CGImageSourceCreateWithURL(url as CFURL, nil) != nil else {
            log.error("not a readable image: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        let name = uniqueName(for: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        } catch {
            log.error("could not copy wallpaper: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        reload()
        return name
    }

    func remove(_ fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        cache[fileName] = nil
        reload()
    }

    /// The image for a stored name, or nil when the file has gone.
    func image(named fileName: String) -> CGImage? {
        if let cached = cache[fileName] { return cached }
        let url = directory.appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache[fileName] = image
        return image
    }

    private func uniqueName(for proposed: String) -> String {
        let base = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        var name = proposed
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return name
    }
}
