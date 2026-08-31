import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Which trashed items to remove. Pure, so the arithmetic that decides to delete things is
/// table-tested rather than trusted.
enum TrashPolicy {
    struct Item: Equatable {
        var url: URL
        /// When it *arrived in the trash*, not when the file was created. A year-old document
        /// trashed yesterday is one day old for this purpose.
        var dateTrashed: Date
        var size: Int64
    }

    struct Settings: Equatable {
        var deleteAfterDays: Int?
        var sizeCapBytes: Int64?
    }

    static func itemsToRemove(from items: [Item], settings: Settings, now: Date) -> [Item] {
        var doomed: [Item] = []
        var remaining = items

        if let days = settings.deleteAfterDays, days > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) {
            let expired = remaining.filter { $0.dateTrashed < cutoff }
            doomed += expired
            remaining.removeAll { item in expired.contains(item) }
        }

        if let cap = settings.sizeCapBytes, cap > 0 {
            // Oldest first: if the trash has to shrink, the thing you're least likely to want back
            // is the thing that has been in there longest.
            var total = remaining.reduce(Int64(0)) { $0 + $1.size }
            for item in remaining.sorted(by: { $0.dateTrashed < $1.dateTrashed }) where total > cap {
                doomed.append(item)
                total -= item.size
            }
        }

        return doomed
    }
}

/// Empties old items out of the Trash.
///
/// The one feature here that genuinely deletes — items in the Trash have nowhere further to go —
/// so it ships disabled, defaults to a conservative 30 days, and logs every single removal.
final class TrashCleanupFeature: Feature, ObservableObject {
    let id = "trash-cleanup"
    let category = FeatureCategory.files
    let title = "Trash Cleanup"
    let summary = "Empty old items from the Trash"
    let details = """
        Permanently removes items that have been in the Trash longer than you choose, and can keep \
        the Trash under a size limit by clearing the oldest items first.

        This is the one thing Sarvkrit does that can't be undone — items in the Trash have nowhere \
        further to go. It runs once an hour, never on a schedule you can't see, and every removal \
        is written to the log.
        """
    let symbolName = "trash"
    let requirements: Set<Requirement> = []

    /// macOS offers no API to ask whether Full Disk Access has been granted; the only honest test
    /// is to try the read and see. Surfaced in this feature's own pane rather than through
    /// `PermissionsManager`, which stays Accessibility-only.
    enum Access: Equatable {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var lastRemovalCount = 0
    @Published private(set) var lastRunDate: Date?
    /// How many items are in the Trash at all. Shown next to how many match, so "0 to remove"
    /// reads as "nothing is old enough yet" rather than "this is broken".
    @Published private(set) var trashItemCount = 0

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "TrashCleanup")
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let trashURL: URL?
    private var timer: Timer?

    private static let daysKey = "trashCleanup.deleteAfterDays"
    private static let capKey = "trashCleanup.sizeCapMB"

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, trashURL: URL? = nil) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.trashURL = trashURL ?? (try? fileManager.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))
        if defaults.object(forKey: Self.daysKey) == nil {
            defaults.set(30, forKey: Self.daysKey)
        }
    }

    var deleteAfterDays: Int {
        get { defaults.integer(forKey: Self.daysKey) }
        set { defaults.set(newValue, forKey: Self.daysKey) }
    }

    /// 0 means "no cap", which is the default — a size limit that silently deletes is not something
    /// to opt someone into.
    var sizeCapMB: Int {
        get { defaults.integer(forKey: Self.capKey) }
        set { defaults.set(newValue, forKey: Self.capKey) }
    }

    var settings: TrashPolicy.Settings {
        TrashPolicy.Settings(
            deleteAfterDays: deleteAfterDays > 0 ? deleteAfterDays : nil,
            sizeCapBytes: sizeCapMB > 0 ? Int64(sizeCapMB) * 1_048_576 : nil
        )
    }

    func activate() {
        run()
        // Hourly. The trash is not time-critical, and a tight loop over it is exactly the kind of
        // idle cost this app has spent effort removing.
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in self?.run() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(TrashCleanupDetailView(feature: self))
    }

    /// Everything currently in the Trash, or nil if it can't be read — which in practice means
    /// Full Disk Access hasn't been granted.
    func currentItems() -> [TrashPolicy.Item]? {
        guard let trashURL else { return nil }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.addedToDirectoryDateKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return nil }

        return contents.compactMap { url in
            (url as NSURL).removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(
                forKeys: [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey]
            ) else { return nil }
            return TrashPolicy.Item(
                url: url,
                dateTrashed: values.addedToDirectoryDate ?? values.creationDate ?? Date(),
                size: Int64(values.fileSize ?? 0)
            )
        }
    }

    @discardableResult
    func run(now: Date = Date(), dryRun: Bool = false) -> [TrashPolicy.Item] {
        guard let items = currentItems() else {
            trashItemCount = 0
            access = .denied
            log.error("cannot read the Trash — Full Disk Access is probably not granted")
            return []
        }
        access = .granted
        trashItemCount = items.count

        let doomed = TrashPolicy.itemsToRemove(from: items, settings: settings, now: now)
        guard !dryRun else { return doomed }

        var removed = 0
        for item in doomed {
            do {
                try fileManager.removeItem(at: item.url)
                removed += 1
                log.info("permanently removed \(item.url.lastPathComponent, privacy: .public) from the Trash")
            } catch {
                log.error("could not remove \(item.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        lastRemovalCount = removed
        lastRunDate = now
        return doomed
    }

    /// The read-only probe the pane runs when it opens, done off the main thread.
    ///
    /// Enumerating the Trash stats every item, and it was running synchronously on main every time
    /// the pane was shown — which is main-thread time the event tap is also waiting on. The pane
    /// renders immediately with whatever it already knew and updates when the answer lands.
    func probe() {
        Self.probeQueue.async { [weak self] in
            guard let self else { return }
            let items = self.currentItems()
            DispatchQueue.main.async {
                guard let items else {
                    self.trashItemCount = 0
                    self.access = .denied
                    self.log.error("cannot read the Trash — Full Disk Access is probably not granted")
                    return
                }
                self.access = .granted
                self.trashItemCount = items.count
            }
        }
    }

    private static let probeQueue =
        DispatchQueue(label: "\(AppIdentity.bundleID).trash-probe")

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
