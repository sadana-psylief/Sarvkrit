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
