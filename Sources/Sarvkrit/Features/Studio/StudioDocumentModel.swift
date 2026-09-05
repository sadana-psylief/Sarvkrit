import AVFoundation
import Combine
import CoreGraphics
import Foundation

/// The editor's state for one project.
///
/// Modelled on `EditorDocumentModel`: a value-type document under an `UndoStack`, with the live
/// interaction state alongside it. The project is geometry and numbers — never bitmaps — so
/// snapshot undo stays cheap at any depth.
@MainActor
final class StudioDocumentModel: ObservableObject {

    enum Inspector: String, CaseIterable, Identifiable {
        case canvas, cursor, camera, captions, audio, keystrokes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .canvas: return "Canvas"
            case .cursor: return "Cursor"
            case .camera: return "Camera"
            case .captions: return "Captions"
            case .audio: return "Audio"
            case .keystrokes: return "Keystrokes"
            }
        }

        var symbolName: String {
            switch self {
            case .canvas: return "rectangle.inset.filled"
            case .cursor: return "cursorarrow"
            case .camera: return "video"
            case .captions: return "captions.bubble"
            case .audio: return "speaker.wave.2"
            case .keystrokes: return "command"
            }
        }
    }

    let bundle: RecordingBundle
    let events: EventLog

    @Published private(set) var project: StudioProject
    @Published var inspector: Inspector = .canvas
    @Published var playhead: TimeInterval = 0
    @Published var isPlaying = false
    @Published var selectedZoom: ZoomSegment.ID?
    @Published var selectedClip: Clip.ID?
    @Published private(set) var isDirty = false
    @Published var timelineZoom: Double = 1
    @Published var exportProgress: Double?

    private var undoStack: UndoStack<StudioProject>
    private lazy var saver = CoalescingSaver<StudioProject>(
        label: "\(AppIdentity.bundleID).studio-save") { [bundle] project in
            try? JSONEncoder().encode(project)
                .write(to: bundle.root.appendingPathComponent("project.json"), options: .atomic)
        }

    init(bundle: RecordingBundle, manifest: RecordingManifest, events: EventLog) {
        self.bundle = bundle
        self.events = events

        let existing = try? JSONDecoder().decode(
            StudioProject.self,
            from: Data(contentsOf: bundle.root.appendingPathComponent("project.json")))

        var project = existing ?? StudioProject(
            canvasSize: manifest.pixelSize.size,
            timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: manifest.duration)]))

        if existing == nil {
            // **The moment that makes this feel like magic.** Stopping a recording should open an
            // editor whose answer is already good: the zooms found, a background chosen from the
            // recording's own colours, padding set. Anything else asks the user to do work before
            // they can see whether the recording was any use.
            project.zooms = ZoomPlanner.plan(events: events,
                                             frameSize: manifest.pixelSize.size,
                                             duration: manifest.duration)
        }

        self.project = project
        self.undoStack = UndoStack(initial: project, depth: 200)
    }

    var duration: TimeInterval { project.duration }

    /// The recording moment currently under the playhead.
    var sourceTime: TimeInterval {
        project.timeline.sourceTime(forOutput: playhead)?.sourceTime ?? 0
    }

    // MARK: - Editing

    /// One committed change: an undo step, a redraw and a save.
    func edit(_ change: (inout StudioProject) -> Void) {
        var updated = project
        change(&updated)
        guard updated != project else { return }
        undoStack.commit(updated)
        project = updated
        isDirty = true
        saver.schedule(updated)
    }

    /// A change mid-gesture. Not an undo step — dragging a slider should cost one, not fifty.
    func editLive(_ change: (inout StudioProject) -> Void) {
        var updated = project
        change(&updated)
        project = updated
        isDirty = true
    }

    func beginGesture() { undoStack.beginTransaction() }

    func endGesture() {
        undoStack.endTransaction(project)
        saver.schedule(project)
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }

    func undo() {
        undoStack.undo()
        project = undoStack.current
        saver.schedule(project)
    }

    func redo() {
        undoStack.redo()
        project = undoStack.current
        saver.schedule(project)
    }

    func markSaved() {
        isDirty = false
        saver.flush()
    }

    // MARK: - Timeline

    func split() {
        edit { $0.timeline = $0.timeline.split(at: playhead) }
    }

    func deleteSelectedClip() {
        guard let selectedClip else { return }
        edit { $0.timeline = $0.timeline.delete(id: selectedClip) }
        self.selectedClip = nil
    }

    func addZoomAtPlayhead() {
        let start = sourceTime
        edit {
            var segment = ZoomSegment(start: start, end: start + 3, level: 2,
                                      anchor: .fixed(CGPoint(x: 0.5, y: 0.5)))
            segment.isAutomatic = false
            $0.zooms.append(segment)
            $0.zooms.sort { $0.start < $1.start }
        }
    }

    func setLevelOfSelectedZoom(_ level: Double) {
        guard let selectedZoom else { return }
        edit {
            guard let index = $0.zooms.firstIndex(where: { $0.id == selectedZoom }) else { return }
            $0.zooms[index].level = min(max(level, ZoomSegment.levelRange.lowerBound),
                                        ZoomSegment.levelRange.upperBound)
        }
    }

    func deleteSelectedZoom() {
        guard let selectedZoom else { return }
        edit { $0.zooms.removeAll { $0.id == selectedZoom } }
        self.selectedZoom = nil
    }

    /// Replaces the generated segments and leaves hand-made ones alone.
    ///
    /// `isAutomatic` exists precisely so this button can be pressed twice without destroying the
    /// user's own work — which is the difference between a useful action and a trap.
    func redetectZooms() {
        let log = events
        let size = project.canvasSize
        let length = duration
        edit {
            let manual = $0.zooms.filter { !$0.isAutomatic }
            let found = ZoomPlanner.plan(events: log, frameSize: size, duration: length)
            $0.zooms = (manual + found).sorted { $0.start < $1.start }
        }
    }

    func step(frames: Int, fps: Int = 60) {
        playhead = min(max(0, playhead + Double(frames) / Double(fps)), max(0, duration - 0.001))
    }

    func step(seconds: Double) {
        playhead = min(max(0, playhead + seconds), max(0, duration - 0.001))
    }
}
