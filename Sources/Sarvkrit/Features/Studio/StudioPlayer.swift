import AVFoundation
import AppKit
import CoreGraphics
import QuartzCore
import VideoToolbox
import os

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

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Studio")

    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var displayLink: CADisplayLink?
    /// Host time of the previous tick, so elapsed time is measured rather than assumed.
    private var lastTickHostTime: CFTimeInterval?
    /// True while the user is dragging the playhead, so the clock does not fight the drag.
    private var isScrubbing = false

    /// Whether the clock is actually running. Observable because its absence silently disabled the
    /// entire editor: no playhead, no redraw, and no decoded frame.
    var isTicking: Bool { displayLink != nil }

    /// The most recently decoded screen frame. Held so a scrub that lands between decodes still
    /// draws the picture rather than flashing black.
    private(set) var decoded: CGImage?

    /// The camera, on its own player.
    ///
    /// **Not one composition with the screen.** An `AVComposition` hands back a single composited
    /// image, and the renderer needs the two apart: it draws the screen, then the zoom, the click
    /// effect and the cursor, and only then the camera on top with its own shape, shadow and
    /// layout. So the camera gets its own item and output, and the screen is the clock it follows.
    private var cameraPlayer: AVPlayer?
    private var cameraOutput: AVPlayerItemVideoOutput?
    private var cameraStartOffset: TimeInterval = 0
    private var cameraDuration: TimeInterval = 0

    /// The most recently decoded camera frame, or nil where the camera was not running.
    private(set) var decodedCamera: CGImage?

    /// Bumped whenever a new frame is ready, so the view knows to redraw without polling.
    @Published private(set) var frameToken = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1

    /// Where the playhead is, in *output* time.
    @Published var playhead: TimeInterval = 0

    /// Set by the model so playback knows where to stop and how to map output to source.
    var duration: TimeInterval = 0
    var sourceTime: (TimeInterval) -> TimeInterval = { $0 }

    /// - Parameter cameraURL: nil for a recording with no camera, which then costs nothing.
    /// - Parameter cameraStartOffset: seconds by which the camera began after the screen.
    init(url: URL, cameraURL: URL? = nil, cameraStartOffset: TimeInterval = 0) {
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

        if let cameraURL {
            let cameraItem = AVPlayerItem(url: cameraURL)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            cameraItem.add(output)
            let camera = AVPlayer(playerItem: cameraItem)
            camera.actionAtItemEnd = .pause
            camera.isMuted = true
            cameraOutput = output
            cameraPlayer = camera
            self.cameraStartOffset = cameraStartOffset
            log.info("editor opened with a camera track, offset \(cameraStartOffset, format: .fixed(precision: 3), privacy: .public)s")
        } else {
            log.info("editor opened with no camera track")
        }

        startClock()
        seek(to: 0)
    }

    deinit { displayLink?.invalidate() }

    // MARK: - Transport

    func play() {
        guard duration > 0 else {
            // Silent until now, so a project whose duration never loaded had a Play button that
            // did nothing and said nothing.
            log.error("play refused: the project has no duration")
            return
        }
        if playhead >= duration - 0.01 { scrub(to: 0) }
        lastTickHostTime = nil
        player.rate = rate
        // Both rates together: the camera runs alongside rather than being seeked frame by frame.
        cameraPlayer?.rate = rate
        isPlaying = true
    }

    func pause() {
        player.rate = 0
        cameraPlayer?.rate = 0
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

    /// Bracketing a drag, so `tick()` and the drag do not write the playhead alternately.
    func beginScrubbing() { isScrubbing = true }
    func endScrubbing() {
        isScrubbing = false
        lastTickHostTime = nil
    }

    func step(seconds: TimeInterval) { scrub(to: playhead + seconds) }

    private func seek(to source: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, source), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Frames

    /// Starts, or restarts, the clock.
    ///
    /// **`NSScreen.main` is the screen holding the key window, and there usually is not one.** This
    /// player is built by `StudioEditorController.open` before its own window exists, and Sarvkrit
    /// is an accessory app, so at the moment a recording stops the key window belongs to whatever
    /// was being demonstrated — or to nothing at all. The optional chain then yielded nil, there was
    /// no fallback and no retry, and `tick()` never ran once for the life of the player.
    ///
    /// That is the whole editor, not just the transport: `tick()` is also the only thing that
    /// decodes a frame, so the preview composited its background over an empty picture.
    ///
    /// Called again when the preview reaches a window, so construction order stops being
    /// load-bearing and the link follows the screen the editor is actually on.
    func startClock() {
        displayLink?.invalidate()
        displayLink = nil
        // NSScreen's display link, macOS 14+. CVDisplayLink is deprecated from 15 and this is the
        // supported replacement at our deployment target.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            log.error("no screen to drive playback from — the preview cannot update")
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = lastTickHostTime.map { now - $0 } ?? 0
        lastTickHostTime = now

        if isPlaying, !isScrubbing {
            // Measured, not assumed: a display link runs at the screen's refresh rate, and the old
            // fixed `rate / 60` ran at double speed on a 120 Hz panel.
            let step = PlaybackClock.advance(playhead: playhead, elapsed: elapsed,
                                             rate: rate, duration: duration)
            playhead = step.playhead
            if step.reachedEnd { pause() }

            // **Only where it is actually needed.** Output time is not source time — a trim makes
            // them diverge — so the player still has to be put in the right place, but `rate` is
            // already carrying it forward at the speed the playhead is moving. This fires at a cut
            // and after a stall. Seeking every tick, keyframe-exact, is what no decoder could
            // service, and it is why playback appeared frozen.
            let wanted = sourceTime(playhead)
            if PlaybackClock.needsResync(playerTime: player.currentTime().seconds, wanted: wanted) {
                seek(to: wanted)
            }
        }

        tickCamera(sourceTime: sourceTime(playhead))

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

    /// Keeps the camera alongside the screen and decodes its frame.
    ///
    /// The screen is the clock; this only corrects the camera when it has drifted past a frame or
    /// two, or where the project cuts. Nil outside the camera's own span is ordinary — it started
    /// after the screen and can stop before it — and `StudioRenderer.drawCamera` draws nothing for
    /// a nil image.
    private func tickCamera(sourceTime source: TimeInterval) {
        guard let cameraPlayer, let cameraOutput else { return }

        if cameraDuration <= 0 {
            let seconds = cameraPlayer.currentItem?.duration.seconds ?? 0
            if seconds.isFinite, seconds > 0 { cameraDuration = seconds }
        }

        guard let wanted = PlaybackClock.cameraTime(forSource: source,
                                                    startOffset: cameraStartOffset,
                                                    cameraDuration: cameraDuration) else {
            decodedCamera = nil
            return
        }

        if PlaybackClock.needsResync(playerTime: cameraPlayer.currentTime().seconds,
                                     wanted: wanted) {
            cameraPlayer.seek(to: CMTime(seconds: wanted, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let itemTime = cameraOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard cameraOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = cameraOutput.copyPixelBuffer(forItemTime: itemTime,
                                                        itemTimeForDisplay: nil) else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        if let image { decodedCamera = image }
    }
}
