import AppKit
import CoreGraphics

/// The timeline: a ruler, one row per track, and a playhead.
///
/// **AppKit rather than SwiftUI**, for the same reason `SelectionView` is: it redraws on every
/// mouse-moved over a waveform that may be tens of thousands of samples, and SwiftUI's diffing is
/// the wrong tool for a surface that is one custom drawing.
@MainActor
final class StudioTimelineView: NSView {

    private let model: StudioDocumentModel
    var onScrub: ((TimeInterval) -> Void)?

    /// **The rows are a value now, not hand-placed rects.** Two tracks used to be hardcoded, each
    /// with its own bespoke hit test, which is why five of the project's own collections had no
    /// representation at all. See `TimelineLayout`.
    private let metrics = TimelineLayout.Metrics()

    private enum Drag {
        case none
        case playhead
        /// Moving any source-time item, on any row. `grabOffset` is how far into the item it was
        /// grabbed, in source seconds, so it does not jump to the pointer.
        case itemBody(TimelineLayout.RowKind, UUID, grabOffset: TimeInterval)
        /// Trimming either edge of one.
        case itemEdge(TimelineLayout.RowKind, UUID, leading: Bool)
        /// Reordering. The move is committed on release, so the whole drag is one undo step and
        /// the clips do not shuffle about under the pointer while it is in flight.
        case clipBody(Clip.ID, from: Int)
        /// Rolling the cut between this clip and the next: one side gains what the other gives up,
        /// and the cut stays where it is in the finished video.
        case clipSeam(Clip.ID, lastTime: TimeInterval)
    }

    /// Where a dragged clip would land, drawn as an insertion line.
    private var dropIndex: Int?

    private var drag: Drag = .none

    private var pollTimer: Timer?
    private var lastDrawnPlayhead: TimeInterval = -1
    private var lastRevision = -1

    init(model: StudioDocumentModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Repaints when the playhead moves.
    ///
    /// **This view used to have no way to know.** It is an `NSView` reading `model.playhead` inside
    /// `draw(_:)`, and it relied entirely on SwiftUI re-running the enclosing body and calling
    /// `updateNSView`. That does not happen reliably: during playback the transport's clock text
    /// updated to `0:40` while the playhead line stayed where it had been drawn eight seconds in.
    /// From the outside that is "when I click play the seekbar never moves" — the picture and the
    /// counter run, and the one thing showing you where you are does not.
    ///
    /// `StudioPreviewView` already solved this for the canvas with a poll of its own; this is the
    /// same answer for the timeline, and it removes the dependency on SwiftUI's update heuristics
    /// rather than hoping about them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pollTimer?.invalidate()
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.model.playhead != self.lastDrawnPlayhead
                    || self.model.revision != self.lastRevision else { return }
                self.lastDrawnPlayhead = self.model.playhead
                self.lastRevision = self.model.revision
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit { pollTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Geometry

    private var rows: [TimelineLayout.Row] {
        TimelineLayout.rows(project: model.project, events: model.events,
                            selection: .init(clip: model.selectedClip,
                                             zoom: model.selectedZoom,
                                             text: model.selectedText,
                                             camera: model.selectedCamera,
                                             mask: model.selectedMask,
                                             pointer: model.selectedPointer))
    }

    /// The rows are laid out once per event, not once per lookup: `rows` walks the whole project.
    private var cachedRows: [TimelineLayout.Row] = []

    static func preferredHeight(rowCount: Int) -> CGFloat {
        TimelineLayout.preferredHeight(rowCount: rowCount)
    }

    /// Kept for the host, which cannot know the row count before the model exists.
    static var preferredHeight: CGFloat { TimelineLayout.preferredHeight(rowCount: 4) }

    private var contentWidth: CGFloat {
        max(1, bounds.width - metrics.gutter - metrics.inset)
    }

    private func x(forOutput t: TimeInterval) -> CGFloat {
        guard model.duration > 0 else { return metrics.gutter }
        return metrics.gutter + CGFloat(t / model.duration) * contentWidth
    }

    private func outputTime(forX x: CGFloat) -> TimeInterval {
        guard model.duration > 0 else { return 0 }
        return min(max(0, Double((x - metrics.gutter) / contentWidth) * model.duration),
                   model.duration)
    }

    /// The recording moment under a point on the timeline, which is what every source-time track
    /// is edited in.
    private func sourceTime(forX x: CGFloat) -> TimeInterval? {
        model.project.timeline.sourceTime(forOutput: outputTime(forX: x))?.sourceTime
    }

    private func rect(ofRow index: Int) -> CGRect {
        TimelineLayout.rect(ofRow: index, in: bounds, metrics: metrics)
    }

    private func rect(of item: TimelineLayout.Item, row index: Int) -> CGRect {
        let from = x(forOutput: item.start)
        let to = x(forOutput: item.end)
        let row = rect(ofRow: index)
        return CGRect(x: from, y: row.minY + 2, width: max(3, to - from), height: row.height - 4)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        context.fill(bounds)

        cachedRows = rows
        drawRuler(in: context)
        for (index, row) in cachedRows.enumerated() {
            drawRow(row, at: index, in: context)
        }
        drawFlags(in: context)
        drawDropLine(in: context)
        drawPlayhead(in: context)
    }

    /// Tick density follows the width, so the labels stay readable rather than merging into a bar.
    private func drawRuler(in context: CGContext) {
        guard model.duration > 0 else { return }
        let candidates: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = candidates.first { CGFloat($0 / model.duration) * contentWidth > 52 }
            ?? candidates[candidates.count - 1]

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)

        var time: TimeInterval = 0
        while time <= model.duration {
            let position = x(forOutput: time).rounded() + 0.5
            context.move(to: CGPoint(x: position, y: metrics.ruler - 6))
            context.addLine(to: CGPoint(x: position, y: metrics.ruler))
            context.strokePath()

            NSAttributedString(string: Self.label(time),
                               attributes: [.font: NSFont.systemFont(ofSize: 9),
                                            .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: CGPoint(x: position + 3, y: 3))
            time += step
        }
    }

    private static func label(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60):\(String(format: "%02d", total % 60))" : "\(total)s"
    }

    /// One row: its name in the gutter, a faint bed, and its items.
    private func drawRow(_ row: TimelineLayout.Row, at index: Int, in context: CGContext) {
        let bed = rect(ofRow: index)

        // The name, so it is obvious what each row is — the thing a timeline of unlabelled bars
        // cannot tell you.
        NSAttributedString(string: row.kind.name,
                           attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                        .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: CGPoint(x: 6, y: bed.minY + bed.height / 2 - 6))

        context.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.1).cgColor)
        context.fill(CGRect(x: metrics.gutter, y: bed.minY + 2,
                            width: max(0, bounds.width - metrics.gutter - metrics.inset),
                            height: bed.height - 4))

        for (position, item) in row.items.enumerated() {
            let box = rect(of: item, row: index)
            let dragging: Bool
            if case .itemBody(_, let id, _) = drag, id == item.id { dragging = true } else if
                case .clipBody(let id, _) = drag, id == item.id { dragging = true } else {
                dragging = false
            }
            let path = CGPath.rounded(box, cornerRadius: 5)

            context.addPath(path)
            context.setFillColor(Self.colour(for: row.kind)
                .withAlphaComponent(item.isMuted ? 0.15
                                    : (dragging ? 0.25 : (item.isSelected ? 0.7 : 0.45))).cgColor)
            context.fillPath()

            // Every item carries an edge, not only the selected one. Two neighbours of the same
            // colour used to read as one continuous bar, which is why a split looked like nothing
            // had happened.
            context.addPath(path)
            context.setStrokeColor(item.isSelected
                ? NSColor.controlAccentColor.cgColor
                : Self.colour(for: row.kind).withAlphaComponent(0.9).cgColor)
            context.setLineWidth(item.isSelected ? 1.5 : 1)
            context.strokePath()

            if box.width > 40 {
                NSAttributedString(
                    string: item.label,
                    attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                 .foregroundColor: NSColor.labelColor])
                    .draw(in: box.insetBy(dx: 5, dy: 4))
            }

            if row.kind == .video {
                drawTrimBadge(forClipAt: position, in: box, context: context)
                // The seam, drawn on the boundary rather than left to a gap between fills.
                if position + 1 < row.items.count {
                    let seamX = x(forOutput: item.end).rounded() + 0.5
                    context.setStrokeColor(NSColor.underPageBackgroundColor.cgColor)
                    context.setLineWidth(2)
                    context.move(to: CGPoint(x: seamX, y: box.minY))
                    context.addLine(to: CGPoint(x: seamX, y: box.maxY))
                    context.strokePath()
                }
            }
        }
    }

    private static func colour(for kind: TimelineLayout.RowKind) -> NSColor {
        switch kind {
        case .video: return .systemOrange
        case .media: return .systemBrown
        case .text: return .systemTeal
        case .camera: return .systemPink
        case .zoom: return .systemIndigo
        case .mask: return .systemGray
        case .pointer: return .systemYellow
        case .caption: return .systemGreen
        }
    }

    /// How much of the recording a clip is hiding, if any.
    ///
    /// Trimming is a window, never a cut, so the material is always still there — and the badge is
    /// what makes that visible rather than merely true. Right-click offers to put it back.
    private func drawTrimBadge(forClipAt index: Int, in rect: CGRect, context: CGContext) {
        let clips = model.project.timeline.clips
        guard clips.indices.contains(index), rect.width > 108 else { return }
        let clip = clips[index]
        let lower = index > 0 ? clips[index - 1].sourceEnd : 0
        let upper = index + 1 < clips.count ? clips[index + 1].sourceStart : model.recordingDuration
        let hidden = max(0, clip.sourceStart - lower) + max(0, upper - clip.sourceEnd)
        guard hidden > 0.15 else { return }

        NSAttributedString(
            string: String(format: "✂︎ %.1fs", hidden),
            attributes: [.font: NSFont.systemFont(ofSize: 9),
                         .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: CGPoint(x: rect.maxX - 46, y: rect.minY + 4))
    }

    /// Moments marked with ⌃⌥⌘M while recording. One keystroke then beats a hunt afterwards.
    private func drawFlags(in context: CGContext) {
        context.setFillColor(NSColor.systemYellow.cgColor)
        for flag in model.events.flags {
            guard let output = model.project.timeline.outputTime(forSource: flag) else { continue }
            context.fill(CGRect(x: x(forOutput: output) - 1, y: 0, width: 2, height: metrics.ruler))
        }
    }

    /// Where a dragged clip would land.
    private func drawDropLine(in context: CGContext) {
        guard case .clipBody = drag, let dropIndex,
              let videoRow = cachedRows.firstIndex(where: { $0.kind == .video }) else { return }
        let clips = model.project.timeline.clips
        var elapsed: TimeInterval = 0
        for clip in clips.prefix(dropIndex) { elapsed += clip.outputDuration }
        let position = x(forOutput: elapsed).rounded() + 0.5
        let row = rect(ofRow: videoRow)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        context.move(to: CGPoint(x: position, y: row.minY))
        context.addLine(to: CGPoint(x: position, y: row.maxY))
        context.strokePath()
    }

    private func drawPlayhead(in context: CGContext) {
        let position = x(forOutput: model.playhead).rounded() + 0.5
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: position, y: 0))
        context.addLine(to: CGPoint(x: position, y: bounds.height))
        context.strokePath()

        context.setFillColor(NSColor.controlAccentColor.cgColor)
        context.fillEllipse(in: CGRect(x: position - 4, y: 0, width: 8, height: 8))
    }

    // MARK: - Hit testing

    /// What is under a point: which row, which item, and whether an edge was grabbed.
    private func hit(at point: CGPoint)
        -> (row: TimelineLayout.Row, index: Int, item: TimelineLayout.Item, edge: Bool?)? {
        let laid = cachedRows.isEmpty ? rows : cachedRows
        for (index, row) in laid.enumerated() where rect(ofRow: index).contains(point) {
            for item in row.items {
                let box = rect(of: item, row: index)
                guard point.x >= box.minX - metrics.edgeGrab,
                      point.x <= box.maxX + metrics.edgeGrab else { continue }
                if abs(point.x - box.minX) <= metrics.edgeGrab { return (row, index, item, true) }
                if abs(point.x - box.maxX) <= metrics.edgeGrab { return (row, index, item, false) }
                return (row, index, item, nil)
            }
            return nil
        }
        return nil
    }

    /// The seam between two clips, if the pointer is near one.
    private func seam(at point: CGPoint) -> Clip.ID? {
        guard let videoRow = (cachedRows.isEmpty ? rows : cachedRows)
            .firstIndex(where: { $0.kind == .video }),
              rect(ofRow: videoRow).contains(point) else { return nil }

        var elapsed: TimeInterval = 0
        let clips = model.project.timeline.clips
        for (index, clip) in clips.enumerated() {
            elapsed += clip.outputDuration
            guard index + 1 < clips.count else { break }
            if abs(point.x - x(forOutput: elapsed)) <= metrics.edgeGrab { return clip.id }
        }
        return nil
    }

    private func select(_ item: TimelineLayout.Item) {
        model.clearTimelineSelection()
        switch item.kind {
        case .video: model.selectedClip = item.id
        case .zoom: model.selectedZoom = item.id
        case .media:
            model.selectedMedia = item.id
            model.inspector = .media
        case .text:
            model.selectedText = item.id
            model.inspector = .text
        case .camera: model.selectedCamera = item.id
        case .mask: model.selectedMask = item.id
        case .pointer: model.selectedPointer = item.id
        case .caption: break
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The clock stops writing the playhead for the length of any timeline drag. Otherwise
        // playback and the drag write it alternately and the handle fights the pointer.
        model.player.beginScrubbing()
        cachedRows = rows

        // A seam takes precedence over a clip body, the way an edge does over a middle: the narrow
        // target is the one you have to aim at.
        if let seamID = seam(at: point) {
            model.clearTimelineSelection()
            model.beginGesture()
            drag = .clipSeam(seamID, lastTime: outputTime(forX: point.x))
            needsDisplay = true
            return
        }

        if let hit = hit(at: point) {
            select(hit.item)
            if hit.row.kind == .video {
                guard let index = model.project.timeline.clips
                    .firstIndex(where: { $0.id == hit.item.id }) else { return }
                drag = .clipBody(hit.item.id, from: index)
                dropIndex = index
            } else if let leading = hit.edge {
                model.beginGesture()
                drag = .itemEdge(hit.row.kind, hit.item.id, leading: leading)
            } else if hit.row.kind != .caption {
                model.beginGesture()
                let grabbed = sourceTime(forX: point.x) ?? 0
                let start = sourceStart(of: hit.item, kind: hit.row.kind) ?? grabbed
                drag = .itemBody(hit.row.kind, hit.item.id, grabOffset: grabbed - start)
            }
            needsDisplay = true
            // **Returns rather than falling through.** It used to set the selection and then start
            // a playhead scrub regardless, so nothing on the timeline could be dragged: every
            // attempt scrubbed instead.
            return
        }

        model.clearTimelineSelection()
        drag = .playhead
        onScrub?(outputTime(forX: point.x))
        needsDisplay = true
    }

    /// An item's start in *source* time, which is what it is stored in.
    private func sourceStart(of item: TimelineLayout.Item,
                             kind: TimelineLayout.RowKind) -> TimeInterval? {
        switch kind {
        case .text: return model.project.textOverlays.first { $0.id == item.id }?.start
        case .zoom: return model.project.zooms.first { $0.id == item.id }?.start
        case .camera: return model.project.cameraSegments.first { $0.id == item.id }?.start
        case .mask: return model.project.masks.first { $0.id == item.id }?.start
        case .pointer: return model.project.pointerHighlights.first { $0.id == item.id }?.start
        case .media: return model.project.mediaOverlays.first { $0.id == item.id }?.start
        case .video, .caption: return nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch drag {
        case .none:
            return
        case .playhead:
            onScrub?(outputTime(forX: point.x))
        case .clipBody:
            dropIndex = insertionIndex(forX: point.x)
        case .clipSeam(let id, let lastTime):
            let time = outputTime(forX: point.x)
            let delta = time - lastTime
            guard abs(delta) > 0.0001 else { return }
            drag = .clipSeam(id, lastTime: time)
            model.rollCut(after: id, by: delta)
        case .itemBody(let kind, let id, let grabOffset):
            guard let source = sourceTime(forX: point.x) else { return }
            model.moveTimelineItem(kind, id: id, toSourceStart: source - grabOffset)
        case .itemEdge(let kind, let id, let leading):
            guard let source = sourceTime(forX: point.x) else { return }
            model.trimTimelineItem(kind, id: id, leading: leading, toSource: source)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .clipBody(_, let from) = drag, let dropIndex, dropIndex != from {
            // Insert-before semantics: dropping to the right of where it came from means the index
            // shifts down by one once the clip is lifted out.
            model.moveClip(from: from, to: dropIndex > from ? dropIndex - 1 : dropIndex)
        }
        switch drag {
        case .none, .playhead, .clipBody:
            break
        case .clipSeam, .itemBody, .itemEdge:
            model.endGesture()
        }
        drag = .none
        dropIndex = nil
        needsDisplay = true
        model.player.endScrubbing()
    }

    /// Which slot in the running order the pointer is over, 0…count.
    private func insertionIndex(forX position: CGFloat) -> Int {
        var elapsed: TimeInterval = 0
        for (index, clip) in model.project.timeline.clips.enumerated() {
            let middle = x(forOutput: elapsed + clip.outputDuration / 2)
            if position < middle { return index }
            elapsed += clip.outputDuration
        }
        return model.project.timeline.clips.count
    }

    // MARK: - The menu

    /// Everything that can be placed at a moment, at the moment you are pointing at.
    ///
    /// **This is the answer to "there is no way to add zoom, click, point manually".** Adding a zoom
    /// by hand had worked all along — an unlabelled magnifying glass in the transport bar and the
    /// `Z` key — and was reported as absent, which is a fair report: two unlabelled glyphs and a
    /// keyboard shortcut with no menu is not a discoverable editor. Masks and camera segments were
    /// worse off, reachable only from inside their own inspector tabs.
    ///
    /// A right-click is where people look for "do something here", and until now this view had no
    /// `menu(for:)` and no `rightMouseDown` at all.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        // The playhead moves to where you clicked first, so every "here" below means the place you
        // pointed at rather than wherever the playhead happened to be left.
        onScrub?(outputTime(forX: point.x))
        needsDisplay = true

        let menu = NSMenu()

        // Whatever is under the pointer, on whichever row — one hit test now serves all of them.
        cachedRows = rows
        if let hit = hit(at: point) {
            select(hit.item)
            switch hit.row.kind {
            case .video:
                add(to: menu, "Duplicate Clip", #selector(menuDuplicateClip))
                add(to: menu, "Delete Clip", #selector(menuDeleteClip), key: "⌫")
                if let clip = model.project.timeline.clips.first(where: { $0.id == hit.item.id }),
                   hasHiddenMaterial(clip) {
                    add(to: menu, "Put Back Trimmed Material", #selector(menuUntrimClip))
                }
                menu.addItem(.separator())
            case .caption:
                break
            default:
                add(to: menu, "Delete \(hit.row.kind.name)", #selector(menuDeleteSelection),
                    key: "⌫")
                menu.addItem(.separator())
            }
        }

        add(to: menu, "Add Zoom Here", #selector(menuAddZoom), key: "Z")
        add(to: menu, "Add Text Here", #selector(menuAddText))
        add(to: menu, "Add Click Here", #selector(menuAddClick))
        add(to: menu, "Add Pointer Highlight Here", #selector(menuAddPointerHighlight))
        add(to: menu, "Add Blur or Highlight Here", #selector(menuAddMask))
        menu.addItem(.separator())
        add(to: menu, "Camera Full Frame Here", #selector(menuCameraFullFrame))
        add(to: menu, "Hide Camera Here", #selector(menuCameraHidden))
        menu.addItem(.separator())
        add(to: menu, "Split Clip Here", #selector(menuSplit), key: "⌘B")
        add(to: menu, "Remove Click Here", #selector(menuRemoveClick))
        return menu
    }

    /// The key equivalent is shown as a label rather than made live: these shortcuts are already
    /// routed by `StudioKeyRouting` on the window, and claiming them here too would mean two owners
    /// for one keystroke.
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let key {
            item.attributedTitle = NSAttributedString(string: "\(title)   \(key)")
        }
        menu.addItem(item)
    }

    private func hasHiddenMaterial(_ clip: Clip) -> Bool {
        let clips = model.project.timeline.clips
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return false }
        let lower = index > 0 ? clips[index - 1].sourceEnd : 0
        let upper = index + 1 < clips.count ? clips[index + 1].sourceStart : model.recordingDuration
        return max(0, clip.sourceStart - lower) + max(0, upper - clip.sourceEnd) > 0.15
    }

    @objc private func menuDuplicateClip() { model.duplicateSelectedClip() }
    @objc private func menuDeleteClip() { model.deleteSelectedClip() }
    @objc private func menuUntrimClip() {
        guard let id = model.selectedClip else { return }
        model.untrimClip(id)
    }
    @objc private func menuAddZoom() { model.addZoomAtPlayhead() }
    @objc private func menuDeleteZoom() { model.deleteSelectedZoom() }
    @objc private func menuAddText() { model.addTextAtPlayhead() }
    @objc private func menuAddClick() { model.addClickAtPlayhead() }
    @objc private func menuRemoveClick() { model.suppressClickNearPlayhead() }
    @objc private func menuAddPointerHighlight() { model.addPointerHighlightAtPlayhead() }
    @objc private func menuAddMask() { model.addMaskAtPlayhead() }
    @objc private func menuCameraFullFrame() { model.addCameraSegment(.fullFrame) }
    @objc private func menuCameraHidden() { model.addCameraSegment(.hidden) }
    @objc private func menuSplit() { model.split() }

    /// Deletes whatever is selected, whichever row it is on.
    @objc private func menuDeleteSelection() {
        guard let selection = model.timelineSelection else { return }
        model.deleteTimelineItem(selection.kind, id: selection.id)
    }

}
