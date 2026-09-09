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
    private var pollTimer: Timer?
    /// Which line of text is being dragged, and where it was grabbed within its own box.
    private var textDrag: (id: TextOverlay.ID, grabOffset: CGPoint)?

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
                guard self.model.player.frameToken != self.lastToken || self.needsDisplay else {
                    return
                }
                self.lastToken = self.model.player.frameToken
                self.needsDisplay = true
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let placement, let inCanvas = canvasPoint(point) else { return }

        // Topmost first, so overlapping lines behave the way the picture looks.
        let boxes = StudioRenderer.textBoxes(project: model.project,
                                             sourceTime: model.sourceTime,
                                             canvas: placement.canvas)
        guard let hit = boxes.reversed().first(where: { $0.rect.contains(inCanvas) }) else {
            model.selectedText = nil
            needsDisplay = true
            return
        }

        model.selectedText = hit.id
        model.inspector = .text
        model.beginGesture()
        textDrag = (hit.id, CGPoint(x: inCanvas.x - hit.rect.midX,
                                    y: inCanvas.y - hit.rect.midY))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let textDrag, let placement,
              let inCanvas = canvasPoint(convert(event.locationInWindow, from: nil))
        else { return }

        // Stored as a fraction of the canvas, so the line keeps its framing at any export size.
        let centre = CGPoint(x: inCanvas.x - textDrag.grabOffset.x,
                             y: inCanvas.y - textDrag.grabOffset.y)
        let unit = CGPoint(x: min(1, max(0, centre.x / placement.canvas.width)),
                           y: min(1, max(0, centre.y / placement.canvas.height)))
        model.updateTextLive(textDrag.id) { $0.origin = unit }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard textDrag != nil else { return }
        textDrag = nil
        model.endGesture()
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
                            clipSource: model.currentClipSource)
        context.restoreGState()
    }
}
