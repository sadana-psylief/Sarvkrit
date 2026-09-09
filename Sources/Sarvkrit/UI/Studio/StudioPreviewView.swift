import AppKit
import CoreGraphics

/// The live canvas.
///
/// **A renderer and nothing else.** Playback, seeking and frame decoding all live in
/// `StudioPlayer`, which the model owns — the previous version created the player inside this view
/// and left the window controller walking the hosting hierarchy to find it, which returned nil and
/// silently killed every transport control.
@MainActor
final class StudioPreviewView: NSView {

    private let model: StudioDocumentModel
    private let cache = StudioRenderer.Cache()
    private var observation: NSObjectProtocol?
    private var lastToken = -1
    private var lastRevision = -1
    private var pollTimer: Timer?
    /// What the pointer is currently doing to the picture.
    private enum Drag {
        /// Where the box was grabbed, relative to its own centre.
        case text(id: TextOverlay.ID, grabOffset: CGPoint)
        /// Where the box was grabbed, relative to its own origin, in canvas points.
        case maskMove(id: StudioMask.ID, index: Int, grabOffset: CGPoint)
        /// `anchor` is the box as it was when the handle was grabbed, in canvas points.
        ///
        /// **Not re-read each event.** `SelectionHandles.resize` is a function of the rect the
        /// handle was grabbed on; feed it its own output and the rect flips when the pointer
        /// crosses the opposite corner, after which every event measures from the flipped edge —
        /// the width becomes the distance the mouse moved since the last event rather than the
        /// distance from the anchor, and the box collapses under a hand still dragging outwards.
        case maskResize(id: StudioMask.ID, index: Int, handle: SelectionHandles.Handle,
                        anchor: CGRect)
    }

    private var drag: Drag?

    init(model: StudioDocumentModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pollTimer?.invalidate()
        guard window != nil else { return }
        // **Restarted here, not only at construction.** The player is built before this window
        // exists, and its display link comes from `NSScreen.main` — the screen with the key window,
        // which at that moment is somebody else's or nothing at all. Asking again now that we are
        // on screen makes construction order stop mattering, and moves the clock to whichever
        // display the editor actually opened on.
        model.player.startClock()
        // Redrawn from the player's frame token rather than from a timer of its own, so the
        // picture and the composite can never disagree about which moment they are showing.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The project as well as the frame: an edit made while paused changes the
                // composite without changing the decoded picture, and nothing else was noticing.
                guard self.model.player.frameToken != self.lastToken
                    || self.model.revision != self.lastRevision
                    || self.needsDisplay else { return }
                self.lastToken = self.model.player.frameToken
                self.lastRevision = self.model.revision
                self.needsDisplay = true
                // The handles move with the picture, and cursor rects are not rebuilt by a
                // redraw — without this the resize cursors stay wherever they were first laid
                // down, pointing at nothing.
                self.window?.invalidateCursorRects(for: self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit { pollTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Placing text by hand

    /// The canvas's geometry inside this view: where it is drawn and how much it is scaled by.
    ///
    /// Computed the same way `draw(_:)` does, so a drag lands exactly where the picture is rather
    /// than on a second guess at the same arithmetic.
    private var placement: (canvas: CGSize, origin: CGPoint, scale: CGFloat)? {
        let (canvas, _) = StudioRenderer.layout(for: model.project)
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        guard scale > 0 else { return nil }
        let drawn = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return (canvas, CGPoint(x: (bounds.width - drawn.width) / 2,
                                y: (bounds.height - drawn.height) / 2), scale)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint? {
        guard let placement else { return nil }
        return CGPoint(x: (point.x - placement.origin.x) / placement.scale,
                       y: (point.y - placement.origin.y) / placement.scale)
    }

    /// Where each visible mask rectangle is, in canvas points — the renderer's own answer.
    private func maskBoxes() -> [(id: StudioMask.ID, index: Int, rect: CGRect)] {
        let (_, imageRect) = StudioRenderer.layout(for: model.project)
        return StudioRenderer.maskBoxes(project: model.project, sourceTime: model.sourceTime,
                                        events: model.events, imageRect: imageRect,
                                        clipSource: model.currentClipSource)
    }

    private func viewRect(_ rect: CGRect) -> CGRect? {
        guard let placement else { return nil }
        return CGRect(x: placement.origin.x + rect.minX * placement.scale,
                      y: placement.origin.y + rect.minY * placement.scale,
                      width: rect.width * placement.scale,
                      height: rect.height * placement.scale)
    }

    /// The box the selected mask's handles belong to, if it is on screen at this moment.
    private func selectedMaskBox() -> (id: StudioMask.ID, index: Int, rect: CGRect)? {
        guard let selected = model.selectedMask else { return nil }
        return maskBoxes().first { $0.id == selected }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let placement, let inCanvas = canvasPoint(point) else { return }

        // **Handles first, and before text.** They sit on and just outside the edge of a box, so
        // anything else winning there would make a corner ungrabbable — and a resize you cannot
        // start is the report this is answering.
        if let box = selectedMaskBox(), let bounds = viewRect(box.rect),
           let handle = SelectionHandles.handle(at: point, bounds: bounds) {
            model.beginGesture()
            drag = .maskResize(id: box.id, index: box.index, handle: handle, anchor: box.rect)
            return
        }

        // Topmost first, so overlapping lines behave the way the picture looks. Text is drawn
        // above the masks, so it is asked first here too.
        let boxes = StudioRenderer.textBoxes(project: model.project,
                                             sourceTime: model.sourceTime,
                                             canvas: placement.canvas)
        if let hit = boxes.reversed().first(where: { $0.rect.contains(inCanvas) }) {
            model.selectedText = hit.id
            model.selectedMask = nil
            model.inspector = .text
            model.beginGesture()
            drag = .text(id: hit.id, grabOffset: CGPoint(x: inCanvas.x - hit.rect.midX,
                                                         y: inCanvas.y - hit.rect.midY))
            needsDisplay = true
            return
        }

        if let hit = maskBoxes().reversed().first(where: { $0.rect.contains(inCanvas) }) {
            model.selectedMask = hit.id
            model.selectedText = nil
            model.inspector = .masks
            model.beginGesture()
            drag = .maskMove(id: hit.id, index: hit.index,
                             grabOffset: CGPoint(x: inCanvas.x - hit.rect.minX,
                                                 y: inCanvas.y - hit.rect.minY))
            needsDisplay = true
            return
        }

        model.selectedText = nil
        model.selectedMask = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let drag, let placement, let inCanvas = canvasPoint(point) else { return }

        switch drag {
        case let .text(id, grabOffset):
            // Stored as a fraction of the canvas, so the line keeps its framing at any export size.
            let centre = CGPoint(x: inCanvas.x - grabOffset.x, y: inCanvas.y - grabOffset.y)
            let unit = CGPoint(x: min(1, max(0, centre.x / placement.canvas.width)),
                               y: min(1, max(0, centre.y / placement.canvas.height)))
            model.updateTextLive(id) { $0.origin = unit }

        case let .maskMove(id, index, grabOffset):
            guard let box = maskBoxes().first(where: { $0.id == id && $0.index == index })
            else { return }
            let moved = CGRect(x: inCanvas.x - grabOffset.x, y: inCanvas.y - grabOffset.y,
                               width: box.rect.width, height: box.rect.height)
            writeMask(id: id, index: index, canvasRect: moved)

        case let .maskResize(id, index, handle, anchor):
            // The floor is a physical size, so it is converted out of view points rather than
            // left as a canvas number that means something different at every window size.
            let resized = SelectionHandles.resize(
                anchor, handle: handle, to: inCanvas,
                constrainAspect: event.modifierFlags.contains(.shift),
                minimumSide: SelectionHandles.minimumSide / placement.scale)
            writeMask(id: id, index: index, canvasRect: resized)
        }
        needsDisplay = true
    }

    /// A canvas rect back into the project, in the recording's own pixels.
    private func writeMask(id: StudioMask.ID, index: Int, canvasRect: CGRect) {
        let (_, imageRect) = StudioRenderer.layout(for: model.project)
        let geometry = StudioRenderer.screenGeometry(
            project: model.project, sourceTime: model.sourceTime, events: model.events,
            imageRect: imageRect, clipSource: model.currentClipSource)
        guard let source = StudioRenderer.sourceRect(canvasRect, project: model.project,
                                                     transform: geometry.transform,
                                                     imageRect: geometry.screenRect)
        else { return }
        model.updateMaskRectLive(id, index: index, to: source)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        model.endGesture()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let box = selectedMaskBox(), let bounds = viewRect(box.rect) else { return }
        for (handle, rect) in SelectionHandles.rects(for: bounds) {
            addCursorRect(rect, cursor: Self.cursor(for: handle))
        }
    }

    private static func cursor(for handle: SelectionHandles.Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        let (canvas, imageRect) = StudioRenderer.layout(for: model.project)
        guard canvas.width > 0, canvas.height > 0 else { return }

        // Fit, never fill: a preview that crops is a preview that lies about the framing.
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let drawn = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let origin = CGPoint(x: (bounds.width - drawn.width) / 2,
                             y: (bounds.height - drawn.height) / 2)

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        StudioRenderer.draw(project: model.project,
                            sourceTime: model.sourceTime,
                            events: model.events,
                            sources: model.frameSources,
                            canvas: canvas,
                            imageRect: imageRect,
                            in: context,
                            cache: cache,
                            clipSource: model.currentClipSource,
                            outputTime: model.playhead,
                            cameraStart: model.cameraStartOffset)
        context.restoreGState()

        drawSelectionHandles(in: context)
    }

    /// The selected mask's outline and its eight grab points.
    ///
    /// **Drawn outside the scaled context, in view points.** A handle sized in canvas points would
    /// be a huge target on a small window and a 2pt one on a large export canvas; the physical
    /// size is what the hand cares about, which is the rule `SelectionHandles` is built around.
    private func drawSelectionHandles(in context: CGContext) {
        guard let box = selectedMaskBox(), let bounds = viewRect(box.rect) else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.stroke(bounds.insetBy(dx: -0.5, dy: -0.5))

        for rect in SelectionHandles.rects(for: bounds).values {
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
        context.restoreGState()
    }
}
