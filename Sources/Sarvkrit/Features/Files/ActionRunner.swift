import AppKit
import Foundation
import os

/// Performs a rule's actions on a file.
///
/// Every action is available in **dry-run** mode, which computes exactly what would happen and
/// touches nothing. That isn't a testing convenience — it's what Stage 2's preview is built on, and
/// nobody should trust an automation that moves their files without showing its work first.
struct ActionRunner {
    enum Mode {
        case perform
        case dryRun
    }

    /// One action's result, in a form both the log and the preview can render.
    struct Outcome: Equatable {
        var summary: String
        /// Where the file ended up, when the action moved it. Later actions operate on this.
        var resultingURL: URL?
        /// The file no longer exists at a usable path; stop the chain.
        var isTerminal: Bool = false
    }

    enum Failure: Error, Equatable {
        case unresolvableDestination
        case fileMissing
        case operationFailed(String)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FileRules")
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Runs actions in order, threading the file's changing location through them. Stops after an
    /// action that relocates or removes the file, since anything later would act on a dead path.
    func run(
        _ actions: [Action],
        on file: FileSnapshot,
        captures: [String] = [],
        mode: Mode,
        now: Date = Date()
    ) -> [Result<Outcome, Failure>] {
        var results: [Result<Outcome, Failure>] = []
        var current = file

        for action in actions {
            let result = perform(action, on: current, captures: captures, mode: mode, now: now)
            results.append(result)

            guard case .success(let outcome) = result else { break }
            if outcome.isTerminal { break }
            if let moved = outcome.resultingURL {
                // Re-snapshot so a later {name} token sees the new name, not the old one.
                current = (mode == .perform ? FileInspector.snapshot(of: moved) : nil)
                    ?? renamed(current, to: moved)
            }
        }
        return results
    }

    // MARK: - Individual actions

    private func perform(
        _ action: Action,
        on file: FileSnapshot,
        captures: [String],
        mode: Mode,
        now: Date
    ) -> Result<Outcome, Failure> {
        let context = RenamePattern.Context(file: file, regexCaptures: captures, now: now)

        switch action {
        case .move(let bookmark):
            guard let destination = resolveFolder(bookmark) else { return .failure(.unresolvableDestination) }
            return relocate(file, into: destination, named: file.fullName, mode: mode, copying: false)

        case .copy(let bookmark):
            guard let destination = resolveFolder(bookmark) else { return .failure(.unresolvableDestination) }
            return relocate(file, into: destination, named: file.fullName, mode: mode, copying: true)

        case .rename(let pattern):
            let newName = RenamePattern.sanitizeComponent(RenamePattern.expand(pattern, context: context))
            return relocate(
                file,
                into: file.url.deletingLastPathComponent(),
                named: newName,
                mode: mode,
                copying: false
            )

        case .sortIntoSubfolder(let pattern):
            let expanded = RenamePattern.expand(pattern, context: context)
            // A subfolder pattern may legitimately contain separators — "{date:yyyy}/{kind}" —
            // so each component is sanitised individually rather than the whole string.
            let components = expanded.split(separator: "/").map { RenamePattern.sanitizeComponent(String($0)) }
            guard !components.isEmpty else { return .failure(.operationFailed("empty subfolder pattern")) }

            var destination = file.url.deletingLastPathComponent()
            for component in components { destination.appendPathComponent(component) }

            if mode == .perform {
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                } catch {
                    return .failure(.operationFailed(error.localizedDescription))
                }
            }
            return relocate(file, into: destination, named: file.fullName, mode: mode, copying: false)

        case .addTag(let tag):
            if mode == .perform {
                var tags = file.tags
                guard !tags.contains(tag) else {
                    return .success(Outcome(summary: "Already tagged “\(tag)”"))
                }
                tags.append(tag)
                // The `URLResourceValues.tagNames` *setter* is macOS 26+; the NSURL form works
                // back to our 14.0 deployment target. Reading via URLResourceValues is fine.
                do { try (file.url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey) }
                catch { return .failure(.operationFailed(error.localizedDescription)) }
            }
            return .success(Outcome(summary: "Add tag “\(tag)”"))

        case .setColorLabel(let label):
            if mode == .perform {
                var values = URLResourceValues()
                values.labelNumber = label.rawValue
                var url = file.url
                do { try url.setResourceValues(values) }
                catch { return .failure(.operationFailed(error.localizedDescription)) }
            }
            return .success(Outcome(summary: "Set colour label"))

        case .moveToTrash:
            // Never unlink. A rules engine that permanently deletes on a mistyped condition is not
            // something anyone should run against their Downloads folder.
            if mode == .perform {
                do { try fileManager.trashItem(at: file.url, resultingItemURL: nil) }
                catch { return .failure(.operationFailed(error.localizedDescription)) }
            }
            return .success(Outcome(summary: "Move to Trash", isTerminal: true))

        case .notify(let message):
            let text = RenamePattern.expand(message, context: context)
            if mode == .perform { log.info("rule notification: \(text, privacy: .public)") }
            return .success(Outcome(summary: "Notify: \(text)"))
        }
    }

    // MARK: - Moving and collisions

    private func relocate(
        _ file: FileSnapshot,
        into folder: URL,
        named name: String,
        mode: Mode,
        copying: Bool
    ) -> Result<Outcome, Failure> {
        let target = uniqueDestination(in: folder, named: name, avoiding: copying ? nil : file.url)
        let verb = copying ? "Copy" : "Move"

        guard target != file.url else {
            return .success(Outcome(summary: "\(verb): already in place"))
        }

        if mode == .perform {
            guard fileManager.fileExists(atPath: file.url.path) else { return .failure(.fileMissing) }
            do {
                if copying {
                    try fileManager.copyItem(at: file.url, to: target)
                } else {
                    try fileManager.moveItem(at: file.url, to: target)
                }
            } catch {
                return .failure(.operationFailed(error.localizedDescription))
            }
        }

        return .success(Outcome(
            summary: "\(verb) to \(target.path)",
            resultingURL: copying ? nil : target,
            isTerminal: false
        ))
    }

    /// Appends ` 2`, ` 3`, … before the extension until the name is free — the same shape Finder
    /// uses, so results look native rather than like a machine wrote them.
    func uniqueDestination(in folder: URL, named name: String, avoiding original: URL? = nil) -> URL {
        let candidate = folder.appendingPathComponent(name)
        if candidate.standardizedFileURL == original?.standardizedFileURL { return candidate }
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        for counter in 2...999 {
            let suffixed = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let attempt = folder.appendingPathComponent(suffixed)
            if !fileManager.fileExists(atPath: attempt.path) { return attempt }
        }
        return folder.appendingPathComponent("\(base) \(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
    }

    // MARK: - Bookmarks

    /// Bookmarks rather than paths: a folder that gets renamed should keep working, and a stale
    /// path is the classic way these tools silently stop doing anything.
    func resolveFolder(_ bookmark: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func renamed(_ file: FileSnapshot, to url: URL) -> FileSnapshot {
        var updated = file
        updated.url = url
        updated.fullName = url.lastPathComponent
        updated.name = url.deletingPathExtension().lastPathComponent
        updated.fileExtension = url.pathExtension
        return updated
    }
}
