import Combine
import Foundation
import os

struct BackgroundPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var style: CaptureBackground
}

/// Saved background settings.
///
/// Built like `RuleStore`: an injectable directory, pretty-printed JSON with sorted keys, and —
/// the rule worth repeating — **an unreadable file is logged and left in place rather than
/// overwritten.** A presets file we can't parse might still be recoverable by hand; silently
/// replacing it with an empty one guarantees it isn't.
final class BackgroundPresetStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")
    private let url: URL

    @Published private(set) var presets: [BackgroundPreset] = []

    init(directory: URL? = nil) {
        let folder = directory ?? Self.defaultDirectory
        self.url = folder.appendingPathComponent("backgrounds.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sarvkrit", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
    }

    func add(name: String, style: CaptureBackground) {
        presets.append(BackgroundPreset(name: name, style: style))
        save()
    }

    func remove(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            presets = try JSONDecoder().decode([BackgroundPreset].self, from: data)
        } catch {
            log.error("background presets unreadable, leaving the file alone: \(error.localizedDescription, privacy: .public)")
            presets = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(presets).write(to: url, options: .atomic)
        } catch {
            log.error("couldn't save background presets: \(error.localizedDescription, privacy: .public)")
        }
    }
}
