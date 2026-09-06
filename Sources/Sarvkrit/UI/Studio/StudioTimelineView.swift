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
    }

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

    private func drawClips(in context: CGContext) {
        var elapsed: TimeInterval = 0
        for clip in model.project.timeline.clips {
            let rect = CGRect(x: x(forOutput: elapsed) ,
                              y: clipTrack.minY,
                              width: max(2, x(forOutput: elapsed + clip.outputDuration)
                                            - x(forOutput: elapsed)),
                              height: clipTrack.height)
            let selected = model.selectedClip == clip.id
            let path = CGPath.rounded(rect.insetBy(dx: 1, dy: 2), cornerRadius: 6)

            context.addPath(path)
            context.setFillColor(NSColor.systemOrange.withAlphaComponent(selected ? 0.55 : 0.38)
                .cgColor)
            context.fillPath()

            if selected {
                context.addPath(path)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1.5)
                context.strokePath()
            }

            // Speed is stated on the clip rather than hidden in an inspector: it changes how every
            // other track maps onto this stretch, so it should never be a surprise.
            let text = clip.speed == 1
                ? String(format: "%.1fs", clip.outputDuration)
                : String(format: "%.1fs · %.2gx", clip.outputDuration, clip.speed)
            NSAttributedString(string: text,
                               attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                            .foregroundColor: NSColor.labelColor])
                .draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 6))
            elapsed += clip.outputDuration
        }
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
        if case .none = drag {} else if case .playhead = drag {} else { model.endGesture() }
        drag = .none
        model.player.endScrubbing()
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
