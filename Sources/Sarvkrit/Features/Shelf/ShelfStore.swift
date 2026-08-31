import AppKit
import Combine
import Foundation
import os

/// What's on the shelf, and the **sole owner of its backing files**.
///
/// Follows `ClipboardStore`'s architecture, including the coalescing background write: persistence
/// runs off the main thread because the event tap's run loop lives there, and a synchronous write
/// on every drop would be felt as input latency system-wide.
///
/// The line it draws hardest: **spilled payloads are ours to delete; referenced files never are.**
final class ShelfStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Shelf")
    private let directory: URL
    private let indexURL: URL
    private let fileManager: FileManager

    @Published private(set) var items: [ShelfItem] = []

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory
        self.indexURL = self.directory.appendingPathComponent("shelf.json")
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Sarvkrit", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }

    // MARK: - Payloads

    func writePayload(_ data: Data, extension ext: String) -> String? {
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            log.error("could not write shelf payload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func payloadURL(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    func readPayload(_ fileName: String) -> Data? { try? Data(contentsOf: payloadURL(for: fileName)) }

    // MARK: - Contents

    /// Newest first — a shelf is a stack you come back to.
    func add(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        self.items.insert(contentsOf: items, at: 0)
        save()
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBackingFiles(of: items[index])
        thumbnails.removeValue(forKey: id)
        items.remove(at: index)
        save()
    }

    /// Removes everything a drag took out, when the shelf is set to clear on drag-out.
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            deleteBackingFiles(of: item)
            thumbnails.removeValue(forKey: item.id)
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        items.forEach(deleteBackingFiles(of:))
        thumbnails.removeAll()
        items = []
        save()
    }

    /// Resolves a parked file, following it if it has been renamed or moved since.
    ///
    /// Returns nil when it's genuinely gone, so a row can be greyed out rather than offering a drag
    /// that would quietly do nothing.
    func resolve(_ reference: ShelfItem.FileReference) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: reference.bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether every file an item points at can still be found.
    func isResolvable(_ item: ShelfItem) -> Bool {
        guard case .files(let references) = item.kind else { return true }
        return references.allSatisfy { resolve($0) != nil }
    }

    // MARK: - Caches
    //
    // On the store, not in view state: the shelf's hosting view is rebuilt when the panel reopens,
    // so a cache held in `@State` would be discarded every time — the same reasoning as
    // `ClipboardStore`.

    private var thumbnails: [UUID: NSImage] = [:]

    func thumbnail(for item: ShelfItem, height: CGFloat) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard case .image(let fileName, _, _, _) = item.kind,
              let data = readPayload(fileName),
              let image = NSImage(data: data)
        else { return nil }

        let scale = image.size.height > 0 ? height / image.size.height : 1
        let size = NSSize(width: max(1, image.size.width * scale), height: height)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()

        thumbnails[item.id] = thumbnail
        return thumbnail
    }

    /// **Only ever store-owned payloads.** A referenced user file has no backing file name, so this
    /// physically cannot reach one — see `ShelfItem.backingFileNames`.
    private func deleteBackingFiles(of item: ShelfItem) {
        for name in item.backingFileNames {
            try? fileManager.removeItem(at: payloadURL(for: name))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            items = try JSONDecoder().decode([ShelfItem].self, from: data)
        } catch {
            log.error("shelf index unreadable: \(error.localizedDescription, privacy: .public)")
            items = []
        }
    }

    // MARK: - Persistence

    private var pendingSnapshot: [ShelfItem]?
    private var isDraining = false
    private var saveLock = os_unfair_lock_s()
    private let saveQueue = DispatchQueue(label: "\(AppIdentity.bundleID).shelf-save", qos: .utility)

    private func save() {
        let snapshot = items
        os_unfair_lock_lock(&saveLock)
        pendingSnapshot = snapshot
        let writerAlreadyRunning = isDraining
        if !writerAlreadyRunning { isDraining = true }
        os_unfair_lock_unlock(&saveLock)

        guard !writerAlreadyRunning else { return }
        saveQueue.async { [weak self] in self?.drainPendingSaves() }
    }

    private func drainPendingSaves() {
        while true {
            os_unfair_lock_lock(&saveLock)
            let snapshot = pendingSnapshot
            pendingSnapshot = nil
            if snapshot == nil { isDraining = false }
            os_unfair_lock_unlock(&saveLock)

            guard let snapshot else { return }
            write(snapshot)
        }
    }

    /// Writes any outstanding change and waits. Called on quit, where "in flight somewhere" isn't
    /// good enough.
    func flush() {
        saveQueue.sync { }
        os_unfair_lock_lock(&saveLock)
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        isDraining = false
        os_unfair_lock_unlock(&saveLock)
        if let snapshot { write(snapshot) }
    }

    private func write(_ snapshot: [ShelfItem]) {
        do {
            try JSONEncoder().encode(snapshot).write(to: indexURL, options: .atomic)
        } catch {
            log.error("could not save shelf index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
