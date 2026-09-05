import AVFoundation
import VideoToolbox
import AppKit
import CoreGraphics
import QuartzCore

/// The live canvas.
///
/// **`AVPlayer` supplies the frames and the clock; `StudioRenderer` composites them.** The player's
/// own layer is never displayed — an `AVPlayerItemVideoOutput` is attached and a display link pulls
/// `copyPixelBuffer(forItemTime:)` each tick, which is exactly the shape that header describes.
///
/// The reason it is not an `AVAssetReader`: **a reader cannot seek.** A reader-based preview would
/// have to be torn down and rebuilt on every scrub, decoding from the nearest keyframe each time —
/// and scrubbing is what a timeline is made of. `AVAssetReader` is still right for the export,
/// which is strictly sequential.
@MainActor
final class StudioPreviewView: NSView {

    private let model: StudioDocumentModel
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var displayLink: CADisplayLink?
    private let cache = StudioRenderer.Cache()
    private var lastDecoded: CGImage?

    /// Rendering at full canvas resolution for a preview is wasted work on a 4K recording, and the
    /// user can choose to spend even less. Never applied silently — the export is unaffected and
    /// the UI says when it is on.
    var qualityFraction: CGFloat = 1

    init(model: StudioDocumentModel) {
        self.model = model
        let item = AVPlayerItem(url: model.bundle.screenURL)
        self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        self.player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return stopLink() }
        startLink()
    }

    deinit { displayLink?.invalidate() }

    private func startLink() {
        stopLink()
        // NSScreen's display link, macOS 14+. CVDisplayLink is deprecated from 15 and this is the
        // supported replacement at our deployment target.
        let link = (window?.screen ?? NSScreen.main)?.displayLink(target: self,
                                                                  selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Playback

    func play() {
        seekPlayer(to: model.sourceTime)
        player.rate = 1
        model.isPlaying = true
    }

    func pause() {
        player.rate = 0
        model.isPlaying = false
    }

    func setRate(_ rate: Float) {
        player.rate = rate
        model.isPlaying = rate != 0
    }

    func scrub(to output: TimeInterval) {
        model.playhead = min(max(0, output), max(0, model.duration))
        seekPlayer(to: model.sourceTime)
        needsDisplay = true
    }

    private func seekPlayer(to source: TimeInterval) {
        player.seek(to: CMTime(seconds: source, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func tick() {
        if model.isPlaying {
            model.playhead = min(model.playhead + 1.0 / 60.0, model.duration)
            if model.playhead >= model.duration { pause() }
            seekPlayer(to: model.sourceTime)
        }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime,
                                               itemTimeForDisplay: nil) {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image { lastDecoded = image }
        }
        needsDisplay = true
    }

    // MARK: - Drawing

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
        // The renderer draws top-left down; this view is flipped, so the two agree already.
        StudioRenderer.draw(project: model.project,
                            sourceTime: model.sourceTime,
                            events: model.events,
                            sources: FrameSources(screen: lastDecoded),
                            canvas: canvas,
                            imageRect: imageRect,
                            in: context,
                            cache: cache)
        context.restoreGState()
    }
}
