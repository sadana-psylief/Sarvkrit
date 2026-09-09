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
        case canvas, cursor, masks, camera, text, captions, audio, keystrokes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .canvas: return "Canvas"
            case .masks: return "Masks"
            case .cursor: return "Cursor"
            case .camera: return "Camera"
            case .text: return "Text"
            case .captions: return "Captions"
            case .audio: return "Audio"
            case .keystrokes: return "Keystrokes"
            }
        }

        var symbolName: String {
            switch self {
            case .canvas: return "rectangle.inset.filled"
            case .masks: return "eye.slash"
            case .cursor: return "cursorarrow"
            case .camera: return "video"
            case .text: return "textformat"
            case .captions: return "captions.bubble"
            case .audio: return "speaker.wave.2"
            case .keystrokes: return "command"
            }
        }
    }

    let bundle: RecordingBundle
    let events: EventLog
    /// How long the recording itself runs, which is the furthest a trim can ever be undone to.
    let recordingDuration: TimeInterval

    @Published private(set) var project: StudioProject
    @Published var inspector: Inspector = .canvas
    /// Playback lives here rather than in a view, so nothing has to go looking for it.
    let player: StudioPlayer
    @Published var selectedZoom: ZoomSegment.ID?
    @Published var selectedClip: Clip.ID?
    @Published var selectedText: TextOverlay.ID?
    @Published var selectedCamera: CameraSegment.ID?
    @Published var selectedMask: StudioMask.ID?
    @Published var selectedPointer: PointerHighlight.ID?
    /// Clears every timeline selection.
    ///
    /// **One call rather than nilling five properties by hand at each site.** Selection used to be
    /// two properties kept mutually exclusive by every writer remembering to nil the other, which
    /// does not scale to the six kinds the timeline now shows.
    func clearTimelineSelection() {
        selectedClip = nil
        selectedZoom = nil
        selectedText = nil
        selectedCamera = nil
        selectedMask = nil
        selectedPointer = nil
    }

    /// How many rows the timeline has, so the view can be tall enough for them.
    var timelineRowCount: Int {
        TimelineLayout.rows(project: project, events: events).count
    }

    /// Whatever is selected on the timeline, if anything.
    var timelineSelection: (kind: TimelineLayout.RowKind, id: UUID)? {
        if let selectedClip { return (.video, selectedClip) }
        if let selectedZoom { return (.zoom, selectedZoom) }
        if let selectedText { return (.text, selectedText) }
        if let selectedCamera { return (.camera, selectedCamera) }
        if let selectedMask { return (.mask, selectedMask) }
        if let selectedPointer { return (.pointer, selectedPointer) }
        return nil
    }

    /// Bumped on every edit.
    ///
    /// **The canvas and the timeline poll this.** Both are `NSView`s that read the project inside
    /// `draw(_:)`, and both relied on SwiftUI re-running the enclosing body and calling
    /// `updateNSView` — which does not happen reliably, as the playhead already taught us. So an
    /// edit made while paused did not repaint anything: adding text put nothing on screen until
    /// playback or a scrub happened to nudge it.
    @Published private(set) var revision = 0
    @Published private(set) var isDirty = false
    /// Whether the shortcuts sheet is up. Set from the window's ⌘/ and cleared by the sheet.
    @Published var isShowingShortcuts = false
    @Published var exportProgress: Double?

    private var undoStack: UndoStack<StudioProject>
    /// The project exactly as it opened, for "undo every edit".
    ///
    /// Kept here rather than read back off the undo stack, whose history is trimmed at its depth —
    /// after two hundred edits the first state is genuinely gone from it.
    private let originalProject: StudioProject
    private lazy var saver = CoalescingSaver<StudioProject>(
        label: "\(AppIdentity.bundleID).studio-save") { [bundle] project in
            try? JSONEncoder().encode(project)
                .write(to: bundle.root.appendingPathComponent("project.json"), options: .atomic)
        }

    init(bundle: RecordingBundle, manifest: RecordingManifest, events: EventLog) {
        self.bundle = bundle
        self.events = events
        self.recordingDuration = manifest.duration

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
        self.originalProject = project
        // Opened only when the recording actually has one, so a screen-only take pays for no
        // decoder. Nothing read `manifest.hasCamera` before this — which is why the camera was
        // recorded faithfully and then never shown.
        let camera = manifest.hasCamera
            && FileManager.default.fileExists(atPath: bundle.cameraURL.path)
            ? bundle.cameraURL : nil
        self.player = StudioPlayer(url: bundle.screenURL, cameraURL: camera,
                                   cameraStartOffset: manifest.cameraStartOffset)

        // The player needs to know how long the edit is and how to turn an output moment into a
        // recording moment. Both change as the timeline is edited, so they are closures rather
        // than copies.
        player.duration = project.duration
        player.sourceTime = { [weak self] output in
            self?.project.timeline.sourceTime(forOutput: output)?.sourceTime ?? 0
        }
    }

    var playhead: TimeInterval {
        get { player.playhead }
        set { player.scrub(to: newValue) }
    }

    var isPlaying: Bool { player.isPlaying }

    var duration: TimeInterval { project.duration }

    /// The recording moment currently under the playhead.
    var sourceTime: TimeInterval {
        project.timeline.sourceTime(forOutput: playhead)?.sourceTime ?? 0
    }

    /// The source range of the clip the playhead is inside.
    ///
    /// Passed to the renderer so a zoom or a camera move that straddles a cut eases out at the cut
    /// rather than being caught mid-ramp when the picture jumps to different material.
    var currentClipSource: Range<TimeInterval>? {
        guard let clip = project.timeline.sourceTime(forOutput: playhead)?.clip,
              clip.sourceEnd > clip.sourceStart else { return nil }
        return clip.sourceStart..<clip.sourceEnd
    }

    // MARK: - Editing

    /// One committed change: an undo step, a redraw and a save.
    func edit(_ change: (inout StudioProject) -> Void) {
        var updated = project
        change(&updated)
        guard updated != project else { return }
        undoStack.commit(updated)
        project = updated
        revision &+= 1
        player.duration = updated.duration
        isDirty = true
        saver.schedule(updated)
    }

    /// A change mid-gesture. Not an undo step — dragging a slider should cost one, not fifty.
    func editLive(_ change: (inout StudioProject) -> Void) {
        var updated = project
        change(&updated)
        project = updated
        revision &+= 1
        isDirty = true
    }

    func beginGesture() { undoStack.beginTransaction() }

    func endGesture() {
        undoStack.endTransaction(project)
        saver.schedule(project)
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }

    /// What a rendered frame needs from outside the project.
    ///
    /// **One place, used by the live canvas and by "copy this frame".** The screenshot editor states
    /// why next to its own equivalent: the two disagreeing about a background is a failure it has
    /// already had once. Studio managed worse — three of these four fields were never filled at all,
    /// so the camera and any wallpaper simply did not render.
    var frameSources: FrameSources {
        FrameSources(screen: player.decoded,
                     camera: player.decodedCamera,
                     wallpaper: FrameSources.wallpaper(for: project))
    }

    /// Puts the project back to how it opened, and leaves that on the undo stack.
    ///
    /// **Restores the first state rather than re-planning.** Those differ the moment somebody has
    /// edited and then re-detected zooms, and "reset" honestly means "back to how I found it".
    func resetEdits() {
        guard originalProject != project else { return }
        let original = originalProject
        edit { $0 = original }
    }

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

    // MARK: - Editing any track from the timeline

    /// Moves a timeline item so it begins at `sourceStart`, keeping its length.
    ///
    /// **One entry point for every track**, so the timeline needs one drag handler rather than one
    /// per kind — which is what kept masks, camera segments and pointer highlights off it
    /// altogether. Live, because this is a drag: one undo step for the whole gesture.
    func moveTimelineItem(_ kind: TimelineLayout.RowKind, id: UUID,
                          toSourceStart sourceStart: TimeInterval) {
        editLive { project in
            let start = max(0, sourceStart)
            switch kind {
            case .text:
                guard let index = project.textOverlays.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let length = project.textOverlays[index].end - project.textOverlays[index].start
                project.textOverlays[index].start = start
                project.textOverlays[index].end = start + length
            case .zoom:
                guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
                let length = project.zooms[index].end - project.zooms[index].start
                project.zooms[index].start = start
                project.zooms[index].end = start + length
                project.zooms[index].isAutomatic = false
            case .camera:
                guard let index = project.cameraSegments.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let length = project.cameraSegments[index].end
                    - project.cameraSegments[index].start
                project.cameraSegments[index].start = start
                project.cameraSegments[index].end = start + length
            case .mask:
                guard let index = project.masks.firstIndex(where: { $0.id == id }) else { return }
                let length = project.masks[index].end - project.masks[index].start
                project.masks[index].start = start
                project.masks[index].end = start + length
            case .pointer:
                guard let index = project.pointerHighlights
                    .firstIndex(where: { $0.id == id }) else { return }
                let length = project.pointerHighlights[index].end
                    - project.pointerHighlights[index].start
                project.pointerHighlights[index].start = start
                project.pointerHighlights[index].end = start + length
            case .video, .caption:
                // A clip's place is its order, not a time; captions come from the transcript.
                break
            }
        }
    }

    /// Drags one edge of a timeline item to a source moment.
    func trimTimelineItem(_ kind: TimelineLayout.RowKind, id: UUID, leading: Bool,
                          toSource source: TimeInterval) {
        /// Where the edge lands, keeping the item long enough to still be grabbable afterwards.
        /// Returns a pair rather than taking two `inout`s into the same array, which Swift refuses
        /// as overlapping access — and rightly.
        func moved(_ start: TimeInterval, _ end: TimeInterval,
                   minimum: TimeInterval) -> (TimeInterval, TimeInterval) {
            let t = max(0, source)
            return leading ? (min(t, end - minimum), end) : (start, max(t, start + minimum))
        }

        editLive { project in
            switch kind {
            case .text:
                guard let index = project.textOverlays.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let item = project.textOverlays[index]
                let range = moved(item.start, item.end, minimum: TextOverlay.minimumDuration)
                project.textOverlays[index].start = range.0
                project.textOverlays[index].end = range.1
            case .zoom:
                guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
                let item = project.zooms[index]
                let range = moved(item.start, item.end, minimum: ZoomSegment.minimumDuration)
                project.zooms[index].start = range.0
                project.zooms[index].end = range.1
                project.zooms[index].isAutomatic = false
            case .camera:
                guard let index = project.cameraSegments.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let item = project.cameraSegments[index]
                let range = moved(item.start, item.end, minimum: 0.4)
                project.cameraSegments[index].start = range.0
                project.cameraSegments[index].end = range.1
            case .mask:
                guard let index = project.masks.firstIndex(where: { $0.id == id }) else { return }
                let item = project.masks[index]
                let range = moved(item.start, item.end, minimum: 0.4)
                project.masks[index].start = range.0
                project.masks[index].end = range.1
            case .pointer:
                guard let index = project.pointerHighlights
                    .firstIndex(where: { $0.id == id }) else { return }
                let item = project.pointerHighlights[index]
                let range = moved(item.start, item.end,
                                  minimum: PointerHighlight.minimumDuration)
                project.pointerHighlights[index].start = range.0
                project.pointerHighlights[index].end = range.1
            case .video, .caption:
                break
            }
        }
    }

    /// Removes whatever is selected on the timeline, whichever track it is on.
    func deleteTimelineItem(_ kind: TimelineLayout.RowKind, id: UUID) {
        switch kind {
        case .text: removeText(id)
        case .zoom: edit { $0.zooms.removeAll { $0.id == id } }
        case .camera: removeCameraSegment(id)
        case .mask: removeMask(id)
        case .pointer: removePointerHighlight(id)
        case .video: edit { $0.timeline = $0.timeline.delete(id: id) }
        case .caption: break
        }
    }

    /// Per-clip timing: speed, a held last frame, and a dip to black at its cut.
    func updateClip(_ id: Clip.ID, live: Bool = false, _ change: (inout Clip) -> Void) {
        let apply: ((inout StudioProject) -> Void) -> Void = live ? editLive : edit
        apply { project in
            guard let index = project.timeline.clips.firstIndex(where: { $0.id == id }) else {
                return
            }
            change(&project.timeline.clips[index])
            // Speed is clamped where it is defined, so going through `setSpeed` keeps one rule.
            let speed = project.timeline.clips[index].speed
            project.timeline = project.timeline.setSpeed(id: id, speed)
        }
    }

    /// Moves a clip in the running order.
    func moveClip(from index: Int, to destination: Int) {
        edit { $0.timeline = $0.timeline.move(from: index, to: destination) }
    }

    func duplicateSelectedClip() {
        guard let selectedClip else { return }
        edit { $0.timeline = $0.timeline.duplicate(id: selectedClip) }
    }

    /// Live, because this is a drag: one undo step for the whole gesture.
    func rollCut(after id: Clip.ID, by seconds: TimeInterval) {
        editLive { $0.timeline = $0.timeline.roll(after: id, by: seconds) }
    }

    /// Puts back everything a clip's trim is hiding, both ends.
    ///
    /// The payoff the non-destructive model was built for: `sourceStart`/`sourceEnd` are a window,
    /// never a cut, so the material was always still there.
    func untrimClip(_ id: Clip.ID) {
        edit { project in
            guard let index = project.timeline.clips.firstIndex(where: { $0.id == id }) else {
                return
            }
            // Only as far as the neighbours allow, so un-trimming cannot overlap the next shot.
            let lower = index > 0 ? project.timeline.clips[index - 1].sourceEnd : 0
            let upper = index + 1 < project.timeline.clips.count
                ? project.timeline.clips[index + 1].sourceStart : self.recordingDuration
            project.timeline.clips[index].sourceStart = min(project.timeline.clips[index].sourceStart,
                                                            max(0, lower))
            project.timeline.clips[index].sourceEnd = max(project.timeline.clips[index].sourceEnd,
                                                          upper)
        }
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
        player.step(seconds: Double(frames) / Double(fps))
    }

    func step(seconds: Double) {
        player.step(seconds: seconds)
    }

    // MARK: - Trimming

    /// Cuts the dead air out, as one undoable step.
    ///
    /// **A one-shot, not a live filter.** A filter would mean the timeline no longer shows what
    /// will be exported, which breaks the promise the whole editor rests on. This inserts real
    /// cuts the user can then adjust or undo like any other.
    ///
    /// - Returns: how many stretches were removed, so the caller can say so rather than appearing
    ///   to do nothing when a recording has no silence in it.
    @discardableResult
    func removeSilences(envelope: [Float], sampleRate: Double) -> Int {
        let found = SilenceDetector.silences(in: envelope, sampleRate: sampleRate)
        guard !found.isEmpty else { return 0 }
        edit { project in
            // Applied back to front, so removing one stretch does not shift the next one's
            // coordinates out from under it.
            for range in found.reversed() {
                project.timeline = Self.cutting(project.timeline, source: range)
            }
        }
        return found.count
    }

    /// The typing runs worth offering to speed up.
    var typingSuggestions: [TypingDetector.Suggestion] {
        TypingDetector.runs(in: events.keys)
    }

    /// Accepts one suggestion: splits around the run and speeds the middle up.
    func applyTypingSuggestion(_ suggestion: TypingDetector.Suggestion) {
        edit { project in
            project.timeline = Self.speedingUp(project.timeline,
                                               source: suggestion.start..<suggestion.end,
                                               speed: suggestion.suggestedSpeed)
        }
    }

    func applyAllTypingSuggestions() {
        let runs = typingSuggestions
        guard !runs.isEmpty else { return }
        edit { project in
            for run in runs.reversed() {
                project.timeline = Self.speedingUp(project.timeline,
                                                   source: run.start..<run.end,
                                                   speed: run.suggestedSpeed)
            }
        }
    }

    /// Removes a span of *source* time from the edit by splitting around it and deleting the middle.
    private static func cutting(_ timeline: Timeline,
                                source range: Range<TimeInterval>) -> Timeline {
        guard let leading = timeline.outputTime(forSource: range.lowerBound),
              let trailing = timeline.outputTime(forSource: range.upperBound) else {
            return timeline
        }
        let afterFirst = timeline.split(at: leading)
        guard let secondCut = afterFirst.outputTime(forSource: range.upperBound) else {
            return afterFirst
        }
        let afterSecond = afterFirst.split(at: secondCut)
        guard let middle = afterSecond.sourceTime(forOutput: (leading + trailing) / 2)?.clip else {
            return afterSecond
        }
        return afterSecond.delete(id: middle.id)
    }

    /// Splits around a span of source time and sets the middle clip's speed.
    private static func speedingUp(_ timeline: Timeline, source range: Range<TimeInterval>,
                                   speed: Double) -> Timeline {
        guard let leading = timeline.outputTime(forSource: range.lowerBound),
              let trailing = timeline.outputTime(forSource: range.upperBound) else {
            return timeline
        }
        let afterFirst = timeline.split(at: leading)
        guard let secondCut = afterFirst.outputTime(forSource: range.upperBound) else {
            return afterFirst
        }
        let afterSecond = afterFirst.split(at: secondCut)
        guard let middle = afterSecond.sourceTime(forOutput: (leading + trailing) / 2)?.clip else {
            return afterSecond
        }
        return afterSecond.setSpeed(id: middle.id, speed)
    }

    // MARK: - Captions

    /// Runs transcription over the microphone track.
    func transcribe(locale: Locale = .current, vocabulary: [String] = []) async throws {
        let captions = try await Transcriber.transcribe(url: bundle.microphoneURL,
                                                        locale: locale,
                                                        vocabulary: vocabulary)
        edit { $0.captions = captions }
    }

    // MARK: - Presets

    func apply(_ preset: StudioPreset) {
        edit { preset.apply(to: &$0) }
    }

    // MARK: - Masks

    /// Places a click at the playhead, on the pointer.
    ///
    /// **The pointer's own position is the point**, because "add a click here" means the thing under
    /// the cursor at that moment; asking the user to place it as well would be asking twice.
    func addClickAtPlayhead() {
        let start = sourceTime
        guard let point = events.cursorPoint(at: start) else { return }
        edit { $0.clickEdits.added.append(ManualClick(t: start, point: point)) }
    }

    /// Takes out the recorded click nearest the playhead, if there is one close by.
    ///
    /// Suppressed rather than deleted — the recording is never modified, so undo brings it back.
    @discardableResult
    func suppressClickNearPlayhead() -> Bool {
        let t = sourceTime
        let nearest = ClickTrack.effective(recorded: events.clicks, edits: project.clickEdits)
            .filter { abs($0.t - t) <= ClickEffect.duration }
            .min { abs($0.t - t) < abs($1.t - t) }
        guard let nearest else { return false }

        edit { edited in
            // A hand-placed one is removed outright; there is nothing in the recording to remember.
            if let index = edited.clickEdits.added.firstIndex(where: {
                abs($0.t - nearest.t) <= ClickTrack.sameClickTolerance
            }) {
                edited.clickEdits.added.remove(at: index)
            } else {
                edited.clickEdits.suppressed.append(nearest.t)
            }
        }
        return true
    }

    /// Puts a line of text on the video from the playhead, and selects it for editing.
    func addTextAtPlayhead() {
        // **Starts a fade-length early, on purpose.** A line whose range begins exactly at the
        // playhead is fully transparent there — the first frame of its own fade in — so asking for
        // text "here" and seeing nothing appear is the obvious reading of a bug. Beginning slightly
        // before means it is at full strength at the moment you asked for it.
        let overlay = TextOverlay(start: max(0, sourceTime - TextOverlay.defaultFade),
                                  end: sourceTime + 3)
        edit {
            $0.textOverlays.append(overlay)
            $0.textOverlays.sort { $0.start < $1.start }
        }
        selectedText = overlay.id
        inspector = .text
    }

    func updateText(_ id: TextOverlay.ID, _ change: (inout TextOverlay) -> Void) {
        edit { project in
            guard let index = project.textOverlays.firstIndex(where: { $0.id == id }) else { return }
            change(&project.textOverlays[index])
        }
    }

    /// Live, for a drag or a slider: one undo step for the whole gesture.
    func updateTextLive(_ id: TextOverlay.ID, _ change: (inout TextOverlay) -> Void) {
        editLive { project in
            guard let index = project.textOverlays.firstIndex(where: { $0.id == id }) else { return }
            change(&project.textOverlays[index])
        }
    }

    func removeText(_ id: TextOverlay.ID) {
        edit { $0.textOverlays.removeAll { $0.id == id } }
        if selectedText == id { selectedText = nil }
    }

    /// Dims everything around the pointer for a few seconds from the playhead.
    func addPointerHighlightAtPlayhead() {
        let start = sourceTime
        edit {
            $0.pointerHighlights.append(PointerHighlight(start: start, end: start + 3))
            $0.pointerHighlights.sort { $0.start < $1.start }
        }
    }

    func removePointerHighlight(_ id: PointerHighlight.ID) {
        edit { $0.pointerHighlights.removeAll { $0.id == id } }
    }

    func addMaskAtPlayhead() {
        let start = sourceTime
        let size = project.canvasSize
        edit {
            let box = CGRect(x: size.width * 0.3, y: size.height * 0.4,
                             width: size.width * 0.4, height: size.height * 0.15)
            $0.masks.append(StudioMask(rects: [box], start: start, end: start + 3))
        }
    }

    func setMaskMode(_ id: StudioMask.ID, _ mode: StudioMask.Mode) {
        edit {
            guard let index = $0.masks.firstIndex(where: { $0.id == id }) else { return }
            $0.masks[index].mode = mode
        }
    }

    func removeMask(_ id: StudioMask.ID) {
        edit { $0.masks.removeAll { $0.id == id } }
    }

    /// Reads the microphone envelope, then cuts the dead air.
    func removeSilencesFromMicrophone() {
        let url = bundle.microphoneURL
        Task { [weak self] in
            guard let envelope = try? await AudioEnvelope.read(url: url) else { return }
            await MainActor.run { self?.removeSilences(envelope: envelope, sampleRate: 100) }
        }
    }

    // MARK: - Camera

    func addCameraSegment(_ layout: CameraSegment.Layout) {
        let start = sourceTime
        edit {
            $0.cameraSegments.append(CameraSegment(start: start, end: start + 4, layout: layout))
            $0.cameraSegments.sort { $0.start < $1.start }
        }
    }

    func removeCameraSegment(_ id: CameraSegment.ID) {
        edit { $0.cameraSegments.removeAll { $0.id == id } }
    }
}
