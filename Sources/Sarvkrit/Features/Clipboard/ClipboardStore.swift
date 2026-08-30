import AppKit
import Combine
import Foundation
import os

/// The clipboard history, and the **sole owner of its backing files**.
///
/// Images and spilled text live as files beside `clipboard.json`. Every path that drops an entry —
/// cap eviction, a dedupe merge, clearing — deletes that entry's files too. Without one owner this
/// directory grows forever and nobody notices until it is gigabytes.
final class ClipboardStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Clipboard")
    private let directory: URL
    private let indexURL: URL
    private let fileManager: FileManager

    @Published private(set) var items: [ClipboardItem] = []

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory
        self.indexURL = self.directory.appendingPathComponent("clipboard.json")
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Sarvkrit", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    // MARK: - Writing payloads

    /// Writes a payload and hands back the filename to store in the entry. Only the store writes
    /// into its own directory.
    func writePayload(_ data: Data, extension ext: String) -> String? {
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            log.error("could not write clipboard payload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func payloadURL(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func readPayload(_ fileName: String) -> Data? {
        try? Data(contentsOf: payloadURL(for: fileName))
    }

    // MARK: - History

    /// Adds an entry, or moves an identical existing one back to the top.
    func add(_ item: ClipboardItem, limit: Int) {
        if let existingIndex = items.firstIndex(where: { $0.dedupeKey == item.dedupeKey }) {
            var existing = items.remove(at: existingIndex)
            existing.createdAt = item.createdAt
            // `firstCopiedAt` deliberately untouched — it's what "time of first copy" sorts on.
            existing.copyCount += 1
            existing.sourceBundleID = item.sourceBundleID
            // The new copy's payload is redundant — the entry already has one — so delete it
            // rather than orphaning a file for every repeat copy.
            deleteBackingFiles(of: item)
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        enforce(limit: limit)
        save()
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].isPinned != pinned else { return }
        items[index].isPinned = pinned
        save()
    }

    /// Removes one entry and its backing files. The store stays the only thing that touches
    /// its directory.
    func delete(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBackingFiles(of: items[index])
        thumbnails.removeValue(forKey: id)
        items.remove(at: index)
        save()
    }

    func clearHistory() {
        // Every backing file goes, pinned entries included — "clear" has to mean it.
        items.forEach(deleteBackingFiles(of:))
        thumbnails.removeAll()
        items = []
        save()
    }

    /// The order the picker shows, and the order ⌘1–5 index into.
    func ordered(
        sortedBy mode: ClipboardSortMode = .lastCopy,
        pinned position: PinnedPosition = .top
    ) -> [ClipboardItem] {
        items.sorted(by: mode, pinned: position)
    }

    /// A search result carrying the ranges that matched, so the row can bold exactly those
    /// characters rather than guessing.
    struct Result: Identifiable, Equatable {
        var item: ClipboardItem
        /// The string that was actually searched — and the one the row must display, or the
        /// ranges below will point at the wrong characters.
        var displayText: String
        var ranges: [Range<String.Index>]
        var id: UUID { item.id }
    }

    func search(
        _ query: String,
        mode: ClipboardSearch.Mode = .exact,
        sortedBy sort: ClipboardSortMode = .lastCopy,
        pinned position: PinnedPosition = .top
    ) -> [Result] {
        let candidates = ordered(sortedBy: sort, pinned: position)
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return candidates.map { Result(item: $0, displayText: Self.displayText(for: $0), ranges: []) }
        }

        // Pinned entries keep their group even while searching — the point of pinning is that they
        // stay where you expect.
        var scored: [(Result, Int, Bool)] = []
        for item in candidates {
            let text = Self.displayText(for: item)
            guard let match = ClipboardSearch.match(query: trimmed, in: text, mode: mode) else {
                continue
            }
            scored.append((
                Result(item: item, displayText: text, ranges: match.ranges),
                match.score,
                item.isPinned
            ))
        }

        let pinnedHits = scored.filter(\.2).sorted { $0.1 > $1.1 }.map(\.0)
        let rest = scored.filter { !$0.2 }.sorted { $0.1 > $1.1 }.map(\.0)
        return position == .top ? pinnedHits + rest : rest + pinnedHits
    }

    /// The single transformation applied before both searching and display. Doing it once here is
    /// what keeps highlight ranges pointing at the characters the row actually draws.
    static func displayText(for item: ClipboardItem) -> String {
        let collapsed = item.searchableText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "(empty)" : collapsed
    }

    // MARK: - Internals

    /// Trims to the limit, **never evicting a pinned entry**. Pins exist precisely so a snippet
    /// doesn't age out.
    private func enforce(limit: Int) {
        guard limit > 0 else { return }
        let unpinned = items.filter { !$0.isPinned }
        guard unpinned.count > limit else { return }

        let doomed = Set(unpinned.sorted { $0.createdAt > $1.createdAt }.dropFirst(limit).map(\.id))
        for item in items where doomed.contains(item.id) { deleteBackingFiles(of: item) }
        items.removeAll { doomed.contains($0.id) }
    }

    // MARK: - Caches
    //
    // On the store on purpose. The picker's root view is rebuilt every time it opens, so a cache
    // held in view state would be discarded each open — defeating the caching entirely.

    private var thumbnails: [UUID: NSImage] = [:]
    private var appIcons: [String: NSImage] = [:]

    /// A thumbnail for an image entry, decoded once. Decoding a full-resolution screenshot per row
    /// per keystroke while filtering would be very noticeable.
    func thumbnail(for item: ClipboardItem, height: CGFloat) -> NSImage? {
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

    func appIcon(forBundleID bundleID: String) -> NSImage? {
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    private func deleteBackingFiles(of item: ClipboardItem) {
        for name in item.backingFileNames {
            try? fileManager.removeItem(at: payloadURL(for: name))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            log.error("clipboard index unreadable: \(error.localizedDescription, privacy: .public)")
            items = []
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        } catch {
            log.error("could not save clipboard index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
