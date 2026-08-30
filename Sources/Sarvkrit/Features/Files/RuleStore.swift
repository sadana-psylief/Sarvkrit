import Combine
import Foundation
import os

/// Loads and saves rules as JSON in Application Support.
///
/// The directory is injectable so tests never touch the real one.
final class RuleStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "RuleStore")
    private let fileURL: URL

    @Published private(set) var rules: [Rule] = []

    /// Called *after* a mutation has been committed and saved.
    ///
    /// Deliberately a callback rather than a Combine sink on `$rules`: `@Published`
    /// emits during `willSet`, so a subscriber would rewire the folder watcher using the
    /// rules as they were *before* the edit. That's the same trap that made a toggle
    /// rebuild the event tap one step behind earlier in this project.
    var onRulesChanged: (() -> Void)?

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        self.fileURL = base.appendingPathComponent("rules.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sarvkrit", isDirectory: true)
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            rules = Self.exampleRules()
            return
        }
        do {
            rules = try JSONDecoder().decode([Rule].self, from: data)
        } catch {
            // Keep the unreadable file rather than overwriting it — it's the user's automation,
            // and silently replacing it with defaults would destroy work.
            log.error("rules.json could not be decoded: \(error.localizedDescription, privacy: .public)")
            rules = []
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            log.error("could not save rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    func replace(with rules: [Rule]) {
        self.rules = rules
        commit()
    }

    func add(_ rule: Rule) {
        rules.append(rule)
        commit()
    }

    func update(_ rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        commit()
    }

    func delete(id: UUID) {
        rules.removeAll { $0.id == id }
        commit()
    }

    /// Order is semantics here — the first matching rule is the only one that runs — so reordering
    /// is a real edit, not a display preference.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        commit()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        guard rules[index].isEnabled != enabled else { return }
        rules[index].isEnabled = enabled
        commit()
    }

    private func commit() {
        save()
        onRulesChanged?()
    }

    /// Shipped **disabled**, but pointed at Downloads so they're immediately meaningful.
    ///
    /// They previously shipped with no folder at all, which made them unrunnable *and*
    /// un-previewable — the preview button stays disabled until a rule is complete, so the whole
    /// feature read as broken. Nothing moves until the user enables a rule, which is the part that
    /// has to stay deliberate.
    static func exampleRules() -> [Rule] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let bookmark = downloads.flatMap { ActionRunner.bookmark(for: $0) }

        return [
            Rule(
                name: "Sort screenshots by month",
                isEnabled: false,
                folderBookmark: bookmark,
                matchMode: .all,
                conditions: [
                    Condition(attribute: .name, comparison: .beginsWith, value: .text("Screenshot")),
                    Condition(attribute: .kind, comparison: .isExactly, value: .kind(.image)),
                ],
                actions: [.sortIntoSubfolder(pattern: "Screenshots/{date:yyyy-MM}")]
            ),
            Rule(
                name: "File installers away",
                isEnabled: false,
                folderBookmark: bookmark,
                matchMode: .any,
                conditions: [
                    Condition(attribute: .fileExtension, comparison: .isExactly, value: .text("dmg")),
                    Condition(attribute: .fileExtension, comparison: .isExactly, value: .text("pkg")),
                ],
                actions: [.sortIntoSubfolder(pattern: "Installers")]
            ),
        ]
    }
}
