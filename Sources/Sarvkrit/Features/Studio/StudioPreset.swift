import Foundation
import os

/// A saved look, applied to a new project in one click.
///
/// Holds the *style* — background, cursor, captions, camera, keystrokes, aspect — and never the
/// edit. A preset that carried a timeline would be a template for one recording rather than a look
/// for all of them.
struct StudioPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var background = CaptureBackground()
    var aspect: AspectRatio = .original
    var cursor = CursorSettings()
    var captionStyle = CaptionStyle()
    var camera = CameraSettings()
    var keystrokes = KeystrokeSettings()

    init(name: String, from project: StudioProject) {
        self.name = name
        background = project.background
        aspect = project.aspect
        cursor = project.cursor
        captionStyle = project.captionStyle
        camera = project.camera
        keystrokes = project.keystrokes
    }

    /// Style only — the timeline, the zooms and the captions are the recording's, not the preset's.
    func apply(to project: inout StudioProject) {
        project.background = background
        project.aspect = aspect
        project.cursor = cursor
        project.captionStyle = captionStyle
        project.camera = camera
        project.keystrokes = keystrokes
    }
}

/// Where presets live.
///
/// Modelled on `BackgroundPresetStore`, including the rule that matters most: **an unreadable file
/// is logged and left in place, never overwritten.** Silently replacing something a person made,
/// because this build could not parse it, is the worst possible response to a bad read.
@MainActor
final class StudioPresetStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Studio")

    @Published private(set) var presets: [StudioPreset] = []

    private let url: URL
    private var isReadable = true

    static var defaultDirectory: URL {
        CaptureHistoryStore.defaultDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    init(directory: URL? = nil) {
        let folder = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("presets.json")
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            presets = try JSONDecoder().decode([StudioPreset].self, from: Data(contentsOf: url))
        } catch {
            isReadable = false
            log.error("presets unreadable, leaving the file alone: \(error.localizedDescription, privacy: .public)")
        }
    }

    func add(_ preset: StudioPreset) {
        presets.append(preset)
        save()
    }

    func remove(id: StudioPreset.ID) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard isReadable else { return }
        try? JSONEncoder().encode(presets).write(to: url, options: .atomic)
    }
}
