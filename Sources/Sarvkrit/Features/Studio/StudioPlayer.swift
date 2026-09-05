import AVFoundation
import AppKit
import CoreGraphics
import QuartzCore
import VideoToolbox

/// Playback and frame supply for one project.
///
/// **Owned by the model, not found in a view hierarchy.** The first version created the preview
/// inside `NSViewRepresentable.makeNSView` and then walked the hosting view looking for it — which
/// returns nil, because SwiftUI has not built the tree when the window controller asks. Every
/// control that went through that reference was therefore dead: play, pause, and dragging the
/// playhead all silently did nothing, which is exactly what "I cannot really edit" looks like.
///
/// Keeping the player here removes the class of bug rather than the instance: there is nothing to
/// find, so nothing can fail to be found.
@MainActor
final class StudioPlayer: ObservableObject {

    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var displayLink: CADisplayLink?

    /// The most recently decoded screen frame. Held so a scrub that lands between decodes still
    /// draws the picture rather than flashing black.
    private(set) var decoded: CGImage?

    /// Bumped whenever a new frame is ready, so the view knows to redraw without polling.
    @Published private(set) var frameToken = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1

    /// Where the playhead is, in *output* time.
    @Published var playhead: TimeInterval = 0

    /// Set by the model so playback knows where to stop and how to map output to source.
    var duration: TimeInterval = 0
    var sourceTime: (TimeInterval) -> TimeInterval = { $0 }

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        // Never displayed. AVPlayer is here for the decoder and the seek, not for its layer —
        // every frame goes through StudioRenderer before anybody sees it.
        player.isMuted = true
        start()
        seek(to: 0)
    }

    deinit { displayLink?.invalidate() }

    // MARK: - Transport

    func play() {
        guard duration > 0 else { return }
        if playhead >= duration - 0.01 { scrub(to: 0) }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.rate = 0
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    /// J/K/L. Zero stops; the sign is the direction and the magnitude the speed.
    func shuttle(_ direction: Int) {
        guard direction != 0 else { return pause() }
        rate = Float(direction)
        play()
    }

    func scrub(to output: TimeInterval) {
        playhead = min(max(0, output), max(0, duration))
        seek(to: sourceTime(playhead))
    }

    func step(seconds: TimeInterval) { scrub(to: playhead + seconds) }

    private func seek(to source: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, source), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Frames

    private func start() {
        displayLink?.invalidate()
        // NSScreen's display link, macOS 14+. CVDisplayLink is deprecated from 15 and this is the
        // supported replacement at our deployment target.
        let link = (NSScreen.main)?.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        if isPlaying {
            playhead += Double(rate) / 60.0
            if playhead >= duration || playhead <= 0 {
                playhead = min(max(0, playhead), duration)
                pause()
            }
            seek(to: sourceTime(playhead))
        }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                  itemTimeForDisplay: nil) else {
            // Still redraw while scrubbing: the composite depends on the playhead as well as on
            // the frame, so the cursor and the zoom must follow even when the picture has not
            // changed.
            if isPlaying { frameToken &+= 1 }
            return
        }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        if let image { decoded = image }
        frameToken &+= 1
    }
}
