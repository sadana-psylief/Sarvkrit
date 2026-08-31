import Combine
import Foundation
import os

/// Loads and saves snippets as JSON in Application Support.
///
/// Modelled on `RuleStore`, including its handshake: `onSnippetsChanged` is a callback rather than a
/// sink on `$snippets`, because `@Published` emits during `willSet` and a subscriber would rebuild
/// the matcher's table from the snippets as they were *before* the edit.
///
/// The directory is injectable so tests never touch the real one.
final class SnippetStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SnippetStore")
    private let fileURL: URL

    @Published private(set) var snippets: [Snippet] = []

    /// Called *after* a mutation has been committed and saved.
    var onSnippetsChanged: (() -> Void)?

    init(directory: URL? = nil) {
        let base = directory ?? RuleStore.defaultDirectory
        self.fileURL = base.appendingPathComponent("snippets.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            snippets = Self.exampleSnippets()
            return
        }
        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            // Keep the unreadable file rather than overwriting it — these are the user's own
            // snippets, and replacing them with examples would destroy work.
            log.error("snippets.json could not be decoded: \(error.localizedDescription, privacy: .public)")
            snippets = []
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snippets).write(to: fileURL, options: .atomic)
        } catch {
            log.error("could not save snippets: \(error.localizedDescription, privacy: .public)")
        }
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        commit()
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        commit()
    }

    func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        commit()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        guard snippets[index].isEnabled != enabled else { return }
        snippets[index].isEnabled = enabled
        commit()
    }

    private func commit() {
        save()
        onSnippetsChanged?()
    }

    /// Shipped **enabled**, unlike the File Rules examples.
    ///
    /// The asymmetry is deliberate: an enabled file rule silently moves your files, so it has to be
    /// opted into. An enabled snippet does nothing at all until you type its trigger, and a
    /// disabled example teaches nothing — the feature would read as broken until you found the
    /// switch. Every trigger here starts with `;`, so none can fire by accident.
    static func exampleSnippets() -> [Snippet] {
        [
            Snippet(trigger: ";today", expansion: "{date}", style: .prefix),
            Snippet(trigger: ";now", expansion: "{now:yyyy-MM-dd HH:mm}", style: .prefix),
            Snippet(
                trigger: ";sig",
                expansion: "Best,\n",
                style: .prefix
            ),
        ]
    }
}
