import AppKit
import Combine
import CoreGraphics
import Foundation
import os

/// What has been captured, and the sole owner of the files behind it.
///
/// Follows `ShelfStore`'s architecture — JSON index beside UUID-named payloads, thumbnail cache on
/// the store, writes coalesced onto a background queue — with two deliberate differences:
///
/// 1. **We own every byte.** There are no file references and no bookmarks, so `remove` really
///    does delete. `ShelfStore` draws the opposite line for the opposite reason.
/// 2. **There is a retention window.** Old captures are pruned on load, so the folder cannot grow
///    without bound on a machine that is never restarted.
///
/// The coalescing writer is `CoalescingSaver` rather than a third hand-rolled copy.
final class CaptureHistoryStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")
    private let directory: URL
    private let indexURL: URL
    private let fileManager: FileManager

    @Published private(set) var items: [CaptureHistoryItem] = []

    var retention: CaptureRetention.Window {
        didSet {
            guard retention != oldValue else { return }
            pruneExpired()
        }
    }

    private lazy var saver = CoalescingSaver<[CaptureHistoryItem]>(
        label: "\(AppIdentity.bundleID).captures-save"
    ) { [weak self] snapshot in
        self?.writeIndex(snapshot)
    }

    init(directory: URL? = nil,
         fileManager: FileManager = .default,
         retention: CaptureRetention.Window = .month,
         now: Date = Date()) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory
        self.indexURL = self.directory.appendingPathComponent("captures.json")
        self.retention = retention
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
        pruneExpired(now: now)
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Sarvkrit", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    // MARK: - Adding

    func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }
    func url(for item: CaptureHistoryItem) -> URL { url(for: item.fileName) }

    /// Where a copy is also written for the user, if they have chosen a folder.
    ///
    /// The history directory is ours and is named by UUID; this is the human-facing copy, named by
    /// the user's pattern. Two files rather than one because the two have different jobs: the
    /// history needs stable identity across renames, and the user's folder needs a name they can
    /// read.
    var exportFolder: URL?
    var exportPattern: String = CaptureFilename.defaultPattern

    /// Writes a capture and records it. Newest first.
    ///
    /// Returns nil when the write fails, so a caller can say so rather than showing an overlay
    /// pointing at a file that isn't there.
    @discardableResult
    func add(image: CGImage,
             mode: CaptureMode,
             sourceRect: CGRect? = nil,
             displayID: CGDirectDisplayID? = nil,
             sourceBundleID: String? = nil) -> CaptureHistoryItem? {
        guard let data = CaptureWriter.pngData(from: image) else {
            log.error("couldn't encode a capture as PNG")
            return nil
        }
        let fileName = "\(UUID().uuidString).png"
        do {
            try data.write(to: url(for: fileName), options: .atomic)
        } catch {
            log.error("couldn't write a capture: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        exportCopy(of: data, mode: mode)

        let item = CaptureHistoryItem(
            fileName: fileName, mode: mode,
            pixelWidth: image.width, pixelHeight: image.height, byteCount: data.count,
            sourceRect: sourceRect, displayID: displayID, sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        save()
        return item
    }

    /// A readable copy in the user's chosen folder.
    ///
    /// Failing here does not fail the capture: the history copy is already written, so the shot is
    /// not lost — the user simply doesn't get the convenience copy, and the log says why.
    private func exportCopy(of data: Data, mode: CaptureMode) {
        guard let folder = exportFolder else { return }
        let base = CaptureFilename.make(pattern: exportPattern, mode: mode, date: Date())
        let url = CaptureFilename.unique(base: base, extension: "png", in: folder) {
            fileManager.fileExists(atPath: $0.path)
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("couldn't write the capture to the chosen folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replaces an item's pixels in place, keeping its identity and its position in the list.
    ///
    /// This is how the editor hands work back: it never writes to this directory itself, so there
    /// is exactly one writer and the thumbnail cache can be invalidated in the same breath.
    @discardableResult
    func replaceImage(of id: UUID, with image: CGImage) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let data = CaptureWriter.pngData(from: image) else { return false }
        do {
            try data.write(to: url(for: items[index].fileName), options: .atomic)
        } catch {
            log.error("couldn't rewrite a capture: \(error.localizedDescription, privacy: .public)")
            return false
        }
        items[index].pixelWidth = image.width
        items[index].pixelHeight = image.height
        items[index].byteCount = data.count
        thumbnails.removeValue(forKey: id)
        save()
        return true
    }

    // MARK: - Removing

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        try? fileManager.removeItem(at: url(for: items[index]))
        thumbnails.removeValue(forKey: id)
        items.remove(at: index)
        save()
    }

    func clear() {
        for item in items { try? fileManager.removeItem(at: url(for: item)) }
        thumbnails.removeAll()
        items = []
        save()
    }

    /// Drops anything past the retention window. Runs on load and whenever the setting changes.
    func pruneExpired(now: Date = Date()) {
        let expired = Set(CaptureRetention.expired(
            items: items.map { (id: $0.id, createdAt: $0.createdAt) },
            now: now, window: retention))
        guard !expired.isEmpty else { return }
        for item in items where expired.contains(item.id) {
            try? fileManager.removeItem(at: url(for: item))
            thumbnails.removeValue(forKey: item.id)
        }
        items.removeAll { expired.contains($0.id) }
        save()
    }

    // MARK: - Thumbnails

    /// Cached on the store, not in view state: the history pane's hosting view is rebuilt every
    /// time the panel opens, so a cache held in `@State` would be thrown away each time. The same
    /// reasoning `ShelfStore` records.
    private var thumbnails: [UUID: NSImage] = [:]

    func thumbnail(for item: CaptureHistoryItem, height: CGFloat) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let image = NSImage(contentsOf: url(for: item)) else { return nil }
        let scale = image.size.height > 0 ? height / image.size.height : 1
        let size = NSSize(width: max(1, image.size.width * scale), height: height)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()
        thumbnails[item.id] = thumbnail
        return thumbnail
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            items = try JSONDecoder().decode([CaptureHistoryItem].self, from: data)
        } catch {
            // Logged and left in place rather than overwritten: an index we can't read might still
            // be recoverable by hand, and the payloads beside it certainly are.
            log.error("capture index unreadable: \(error.localizedDescription, privacy: .public)")
            items = []
        }
    }

    private func save() { saver.schedule(items) }

    func flush() { saver.flush() }

    private func writeIndex(_ snapshot: [CaptureHistoryItem]) {
        do {
            try JSONEncoder().encode(snapshot).write(to: indexURL, options: .atomic)
        } catch {
            log.error("couldn't save the capture index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
