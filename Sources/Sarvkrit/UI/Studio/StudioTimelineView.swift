import AppKit
import CoreGraphics

/// The timeline: a ruler, the clip track, the zoom track and a playhead.
///
/// **AppKit rather than SwiftUI**, for the same reason `SelectionView` is: it redraws on every
/// mouse-moved over a waveform that may be tens of thousands of samples, and SwiftUI's diffing is
/// the wrong tool for a surface that is one custom drawing.
@MainActor
final class StudioTimelineView: NSView {

    private let model: StudioDocumentModel
    var onScrub: ((TimeInterval) -> Void)?

    private enum Metrics {
        static let ruler: CGFloat = 22
        static let trackHeight: CGFloat = 44
        static let trackGap: CGFloat = 6
        static let inset: CGFloat = 12
        /// A grab this near an edge is a trim, not a move.
        static let edgeGrab: CGFloat = 6
    }

    private enum Drag {
        case none
        case playhead
        case zoomBody(ZoomSegment.ID, grabbedAt: TimeInterval)
        case zoomEdge(ZoomSegment.ID, leading: Bool)
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
                guard self.model.playhead != self.lastDrawnPlayhead else { return }
                self.lastDrawnPlayhead = self.model.playhead
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

    private var contentWidth: CGFloat { max(1, bounds.width - Metrics.inset * 2) }

    private func x(forOutput t: TimeInterval) -> CGFloat {
        guard model.duration > 0 else { return Metrics.inset }
        return Metrics.inset + CGFloat(t / model.duration) * contentWidth
    }

    private func outputTime(forX x: CGFloat) -> TimeInterval {
        guard model.duration > 0 else { return 0 }
        return min(max(0, Double((x - Metrics.inset) / contentWidth) * model.duration),
                   model.duration)
    }

    /// A source moment's place on the timeline, or nil when the edit cut it out.
    private func x(forSource t: TimeInterval) -> CGFloat? {
        model.project.timeline.outputTime(forSource: t).map { x(forOutput: $0) }
    }

    private var clipTrack: CGRect {
        CGRect(x: 0, y: Metrics.ruler, width: bounds.width, height: Metrics.trackHeight)
    }

    private var zoomTrack: CGRect {
        CGRect(x: 0, y: Metrics.ruler + Metrics.trackHeight + Metrics.trackGap,
               width: bounds.width, height: Metrics.trackHeight)
    }

    static var preferredHeight: CGFloat {
        Metrics.ruler + Metrics.trackHeight * 2 + Metrics.trackGap + 8
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        context.fill(bounds)

        drawRuler(in: context)
        drawClips(in: context)
        drawZooms(in: context)
        drawFlags(in: context)
        drawPlayhead(in: context)
    }

    /// Tick density follows the zoom, so the labels stay readable rather than merging into a bar.
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
            context.move(to: CGPoint(x: position, y: Metrics.ruler - 6))
            context.addLine(to: CGPoint(x: position, y: Metrics.ruler))
            context.strokePath()

            let label = NSAttributedString(
                string: Self.label(time),
                attributes: [.font: NSFont.systemFont(ofSize: 9),
                             .foregroundColor: NSColor.secondaryLabelColor])
            label.draw(at: CGPoint(x: position + 3, y: 3))
            time += step
        }
    }

    private static func label(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total)s"
    }

    /// **A cut has to look like a cut.**
    ///
    /// Unselected clips used to have a fill and no border, so two neighbours of the same colour
    /// read as one continuous bar and the only hint of a split was a two-pixel gap from the rounded
    /// inset. "What happens when I split?" was a fair question: visually, almost nothing did.
    ///
    /// Now every clip carries its own edge, the seam between two of them is drawn explicitly, and a
    /// clip that is hiding material says how much — the badge `Clip`'s own doc comment has promised
    /// all along and which nothing drew.
    private func drawClips(in context: CGContext) {
        var elapsed: TimeInterval = 0
        let clips = model.project.timeline.clips

        for (index, clip) in clips.enumerated() {
            let from = x(forOutput: elapsed)
            let to = x(forOutput: elapsed + clip.outputDuration)
            let rect = CGRect(x: from, y: clipTrack.minY,
                              width: max(2, to - from), height: clipTrack.height)
            let selected = model.selectedClip == clip.id
            let dragging: Bool
            if case .clipBody(let id, _) = drag, id == clip.id { dragging = true } else {
                dragging = false
            }
            let path = CGPath.rounded(rect.insetBy(dx: 1, dy: 2), cornerRadius: 6)

            context.addPath(path)
            context.setFillColor(NSColor.systemOrange
                .withAlphaComponent(dragging ? 0.25 : (selected ? 0.55 : 0.38)).cgColor)
            context.fillPath()

            // Every clip, not only the selected one.
            context.addPath(path)
            context.setStrokeColor(selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.systemOrange.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(selected ? 1.5 : 1)
            context.strokePath()

            // Speed is stated on the clip rather than hidden in an inspector: it changes how every
            // other track maps onto this stretch, so it should never be a surprise.
            var text = clip.speed == 1
                ? String(format: "%.1fs", clip.outputDuration)
                : String(format: "%.1fs · %.2gx", clip.outputDuration, clip.speed)
            if clip.hold > 0 { text += String(format: " · hold %.1fs", clip.hold) }
            NSAttributedString(string: text,
                               attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                            .foregroundColor: NSColor.labelColor])
                .draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 6))

            drawTrimBadge(for: clip, at: index, in: rect, context: context)

            elapsed += clip.outputDuration

            // The seam, drawn on the boundary rather than left to a gap in the fills.
            if index + 1 < clips.count {
                let seamX = x(forOutput: elapsed).rounded() + 0.5
                context.setStrokeColor(NSColor.underPageBackgroundColor.cgColor)
                context.setLineWidth(2)
                context.move(to: CGPoint(x: seamX, y: clipTrack.minY + 2))
                context.addLine(to: CGPoint(x: seamX, y: clipTrack.maxY - 2))
                context.strokePath()
            }
        }

        drawDropLine(in: context)
    }

    /// How much of the recording a clip is hiding, if any.
    ///
    /// Trimming is a window, never a cut, so the material is always still there — and the badge is
    /// what makes that visible instead of merely true. Right-click offers to put it back.
    private func drawTrimBadge(for clip: Clip, at index: Int, in rect: CGRect,
                               context: CGContext) {
        let clips = model.project.timeline.clips
        let lower = index > 0 ? clips[index - 1].sourceEnd : 0
        let upper = index + 1 < clips.count ? clips[index + 1].sourceStart : model.recordingDuration
        let hidden = max(0, clip.sourceStart - lower) + max(0, upper - clip.sourceEnd)
        guard hidden > 0.15, rect.width > 92 else { return }

        let label = NSAttributedString(
            string: String(format: "✂︎ %.1fs hidden", hidden),
            attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                         .foregroundColor: NSColor.secondaryLabelColor])
        label.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 22))
    }

    /// Where a dragged clip would land.
    private func drawDropLine(in context: CGContext) {
        guard case .clipBody = drag, let dropIndex else { return }
        var elapsed: TimeInterval = 0
        for clip in model.project.timeline.clips.prefix(dropIndex) {
            elapsed += clip.outputDuration
        }
        let position = x(forOutput: elapsed).rounded() + 0.5
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        context.move(to: CGPoint(x: position, y: clipTrack.minY))
        context.addLine(to: CGPoint(x: position, y: clipTrack.maxY))
        context.strokePath()
    }

    private func drawZooms(in context: CGContext) {
        context.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor)
        context.fill(zoomTrack.insetBy(dx: Metrics.inset, dy: 4))

        for segment in model.project.zooms {
            guard let from = x(forSource: segment.start) else { continue }
            let to = x(forSource: segment.end) ?? bounds.maxX - Metrics.inset
            let rect = CGRect(x: from, y: zoomTrack.minY + 2,
                              width: max(3, to - from), height: zoomTrack.height - 4)
            let selected = model.selectedZoom == segment.id
            let path = CGPath.rounded(rect, cornerRadius: 6)

            context.addPath(path)
            let base = NSColor.systemIndigo
            context.setFillColor(base.withAlphaComponent(
                segment.isDisabled ? 0.15 : (selected ? 0.7 : 0.5)).cgColor)
            context.fillPath()

            if selected {
                context.addPath(path)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1.5)
                context.strokePath()
            }

            guard rect.width > 44 else { continue }
            let follows: String
            if case .followCursor = segment.anchor { follows = " · follows" } else { follows = "" }
            NSAttributedString(
                string: String(format: "%.1fx%@", segment.level, follows),
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                             .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 6))
        }
    }

    /// Moments marked with ⌃⌥⌘M while recording. One keystroke then beats a hunt afterwards.
    private func drawFlags(in context: CGContext) {
        context.setFillColor(NSColor.systemYellow.cgColor)
        for flag in model.events.flags {
            guard let position = x(forSource: flag) else { continue }
            context.fill(CGRect(x: position - 1, y: 0, width: 2, height: Metrics.ruler))
        }
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

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The clock stops writing the playhead for the length of any timeline drag. Otherwise
        // playback and the drag write it alternately and the handle fights the pointer.
        model.player.beginScrubbing()

        if clipTrack.contains(point) {
            // A seam takes precedence over the clip body, the way a zoom's edge does over its
            // middle: the narrow target is the one you have to aim at.
            if let seam = seam(at: point) {
                model.selectedClip = nil
                model.beginGesture()
                drag = .clipSeam(seam, lastTime: outputTime(forX: point.x))
                needsDisplay = true
                return
            }
            if let hit = clip(at: point),
               let index = model.project.timeline.clips.firstIndex(where: { $0.id == hit.id }) {
                model.selectedClip = hit.id
                model.selectedZoom = nil
                drag = .clipBody(hit.id, from: index)
                dropIndex = index
                needsDisplay = true
                // **Returns rather than falling through.** It used to set the selection and then
                // start a playhead scrub regardless, so a clip could never be dragged: every
                // attempt scrubbed instead.
                return
            }
        }

        if zoomTrack.contains(point), let hit = zoom(at: point) {
            model.selectedZoom = hit.segment.id
            model.selectedClip = nil
            model.beginGesture()
            drag = hit.edge.map { .zoomEdge(hit.segment.id, leading: $0) }
                ?? .zoomBody(hit.segment.id, grabbedAt: outputTime(forX: point.x))
            needsDisplay = true
            return
        }

        if clipTrack.contains(point) {
            model.selectedClip = clip(at: point)?.id
            model.selectedZoom = nil
            needsDisplay = true
        }

        drag = .playhead
        onScrub?(outputTime(forX: point.x))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let time = outputTime(forX: point.x)

        switch drag {
        case .none:
            return
        case .clipBody:
            dropIndex = insertionIndex(forX: point.x)
        case .clipSeam(let id, let lastTime):
            let delta = time - lastTime
            guard abs(delta) > 0.0001 else { return }
            drag = .clipSeam(id, lastTime: time)
            model.rollCut(after: id, by: delta)
        case .playhead:
            onScrub?(time)
        case .zoomBody(let id, let grabbedAt):
            let delta = time - grabbedAt
            guard abs(delta) > 0.0001 else { return }
            drag = .zoomBody(id, grabbedAt: time)
            moveZoom(id) { segment in
                segment.start += delta
                segment.end += delta
            }
        case .zoomEdge(let id, let leading):
            moveZoom(id) { segment in
                if leading {
                    segment.start = min(time, segment.end - ZoomSegment.minimumDuration)
                } else {
                    segment.end = max(time, segment.start + ZoomSegment.minimumDuration)
                }
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .clipBody(_, let from) = drag, let dropIndex, dropIndex != from {
            // Insert-before semantics: dropping to the right of where it came from means the
            // index shifts down by one once the clip is lifted out.
            model.moveClip(from: from, to: dropIndex > from ? dropIndex - 1 : dropIndex)
        }
        if case .none = drag {} else if case .playhead = drag {} else if case .clipBody = drag {
        } else { model.endGesture() }
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

    /// The clip *before* a seam the pointer is close to, if any. Nil for the outer edges, which
    /// are trims rather than seams.
    private func seam(at point: CGPoint) -> Clip.ID? {
        var elapsed: TimeInterval = 0
        let clips = model.project.timeline.clips
        for (index, clip) in clips.enumerated() {
            elapsed += clip.outputDuration
            guard index + 1 < clips.count else { break }
            if abs(point.x - x(forOutput: elapsed)) <= Metrics.edgeGrab { return clip.id }
        }
        return nil
    }

    /// Editing a zoom marks it as the user's, so "Re-detect" will not take it away again.
    private func moveZoom(_ id: ZoomSegment.ID, _ change: (inout ZoomSegment) -> Void) {
        model.editLive { project in
            guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            change(&project.zooms[index])
            project.zooms[index].isAutomatic = false
            project.zooms.sort { $0.start < $1.start }
        }
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

        if zoomTrack.contains(point), let hit = zoom(at: point) {
            model.selectedZoom = hit.segment.id
            model.selectedClip = nil
            add(to: menu, "Delete Zoom", #selector(menuDeleteZoom))
            menu.addItem(.separator())
        }

        if clipTrack.contains(point), let hit = clip(at: point) {
            model.selectedClip = hit.id
            model.selectedZoom = nil
            add(to: menu, "Duplicate Clip", #selector(menuDuplicateClip))
            add(to: menu, "Delete Clip", #selector(menuDeleteClip), key: "⌫")
            if hasHiddenMaterial(hit) {
                add(to: menu, "Put Back Trimmed Material", #selector(menuUntrimClip))
            }
            menu.addItem(.separator())
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

    private func zoom(at point: CGPoint) -> (segment: ZoomSegment, edge: Bool?)? {
        for segment in model.project.zooms {
            guard let from = x(forSource: segment.start),
                  let to = x(forSource: segment.end) else { continue }
            guard point.x >= from - Metrics.edgeGrab, point.x <= to + Metrics.edgeGrab else {
                continue
            }
            if abs(point.x - from) <= Metrics.edgeGrab { return (segment, true) }
            if abs(point.x - to) <= Metrics.edgeGrab { return (segment, false) }
            return (segment, nil)
        }
        return nil
    }

    private func clip(at point: CGPoint) -> Clip? {
        var elapsed: TimeInterval = 0
        for clip in model.project.timeline.clips {
            let from = x(forOutput: elapsed)
            let to = x(forOutput: elapsed + clip.outputDuration)
            if point.x >= from && point.x <= to { return clip }
            elapsed += clip.outputDuration
        }
        return nil
    }
}
