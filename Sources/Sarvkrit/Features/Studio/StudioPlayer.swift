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
    private var clock: Timer?
    /// Host time of the previous tick, so elapsed time is measured rather than assumed.
    private var lastTickHostTime: CFTimeInterval?
    /// True while the user is dragging the playhead, so the clock does not fight the drag.
    private var isScrubbing = false

    /// Whether the clock is actually running. Observable because its absence silently disabled the
    /// entire editor: no playhead, no redraw, and no decoded frame.
    var isTicking: Bool { clock?.isValid ?? false }

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

    /// The soundtrack: narration and system audio, cut to the timeline.
    ///
    /// **The composition the exporter builds, played as-is.** `StudioAudio.composition` already
    /// returns the project's audio gain-staged, speed-scaled and offset to match the edit, in
    /// *output* time — which is exactly what a preview needs. Playing anything else would be a
    /// second audio path, and two paths are how an editor ends up sounding different from the file
    /// it produces.
    ///
    /// On its own player for the same reason the camera is: the screen's item exists to decode
    /// pictures, and its own track carries system audio at the recording's original gain with none
    /// of the per-clip mixing applied.
    private var soundtrackPlayer: AVPlayer?

    /// Whether there is a soundtrack loaded at all. False for a screen-only take, which then costs
    /// nothing.
    var hasSoundtrack: Bool { soundtrackPlayer != nil }

    /// Exposed for the same reason `isTicking` is: the absence of sound is silent, so it has to be
    /// observable from outside to be diagnosable at all.
    var soundtrackRate: Float? { soundtrackPlayer?.rate }
    var soundtrackTime: TimeInterval? { soundtrackPlayer?.currentTime().seconds }

    /// Bumped whenever a new frame is ready, so the view knows to redraw without polling.
    @Published private(set) var frameToken = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1
    /// Whether reaching the end starts again rather than stopping. ⌘L.
    @Published var loops = false

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
        //
        // **Muted on purpose, and no longer the reason the editor is silent.** This item's own
        // audio track is the raw system audio at the recording's gain, positioned in source time
        // and with no per-clip volume or mute applied. The soundtrack comes from
        // `setSoundtrack(asset:mix:)` instead, which is the composition the export uses.
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

    deinit { clock?.invalidate() }

    // MARK: - Sound

    /// Hands the player the project's soundtrack. Nil clears it.
    ///
    /// Called again whenever the edit changes the sound — a trim, a speed change, a volume slider —
    /// because the composition is cut to the timeline and a stale one plays the previous edit.
    func setSoundtrack(asset: AVAsset?, mix: AVAudioMix?) {
        soundtrackPlayer?.rate = 0
        soundtrackPlayer = nil
        guard let asset else { return }

        let item = AVPlayerItem(asset: asset)
        item.audioMix = mix
        // Shuttling at 2× should stay intelligible rather than turning into chipmunks, and this is
        // the algorithm that survives a rate change without artefacts on speech.
        item.audioTimePitchAlgorithm = .timeDomain
        let made = AVPlayer(playerItem: item)
        made.actionAtItemEnd = .pause
        soundtrackPlayer = made
        // Straight to wherever the playhead already is, so turning the sound on mid-session does
        // not start it from the beginning.
        seekSoundtrack(to: playhead)
        if isPlaying { made.rate = soundtrackRate(for: rate) }
        log.info("soundtrack loaded")
    }

    /// **Output time, not source time.** The composition is already cut to the timeline, so its
    /// clock is the playhead's. Seeking it like the video — which tracks source time — would put
    /// every word out by however much the edit has trimmed.
    private func seekSoundtrack(to output: TimeInterval) {
        soundtrackPlayer?.seek(to: CMTime(seconds: max(0, output), preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Audio does not run backwards. `AVPlayer` refuses a negative rate for sound, and J on the
    /// shuttle is for finding a frame rather than for listening, so reverse is silent.
    private func soundtrackRate(for rate: Float) -> Float { rate > 0 ? rate : 0 }

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
        // All three rates together: the camera and the soundtrack run alongside rather than being
        // seeked frame by frame.
        cameraPlayer?.rate = rate
        soundtrackPlayer?.rate = soundtrackRate(for: rate)
        isPlaying = true
    }

    func pause() {
        player.rate = 0
        cameraPlayer?.rate = 0
        soundtrackPlayer?.rate = 0
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
        seekSoundtrack(to: playhead)
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
    /// **A timer, not a display link, and that is the fix.** The previous version took a
    /// `CADisplayLink` from `NSScreen.main` — the screen holding the *key window*. This player is
    /// built by `StudioEditorController.open` before its own window exists, and Sarvkrit is an
    /// accessory app, so at the moment a recording stops the key window belongs to whatever was
    /// being demonstrated, or to nothing at all. The optional chain yielded nil, there was no
    /// fallback and no retry, and `tick()` never ran once for the life of the player.
    ///
    /// That silently disabled the whole editor rather than just the transport: `tick()` is also the
    /// only thing that decodes a frame, so the canvas composited its background over an empty
    /// picture. A display link also stops firing for an app with nothing on screen, which makes it
    /// untestable and fragile for a clock that has to keep running while a window is being opened.
    ///
    /// A timer on the main run loop in `.common` mode depends on none of that. Vsync alignment
    /// buys nothing here — every frame goes through `StudioRenderer` into a `CGContext`, and the
    /// preview polls on a timer of its own already — and `PlaybackClock` measures the elapsed time
    /// of each tick rather than assuming it, so an irregular interval costs nothing either.
    ///
    /// This removes the class of bug rather than the instance, which is the same reasoning that put
    /// the player on the model instead of in the view hierarchy.
    func startClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = lastTickHostTime.map { now - $0 } ?? 0
        lastTickHostTime = now

        if isPlaying, !isScrubbing {
            // Measured, not assumed: a display link runs at the screen's refresh rate, and the old
            // fixed `rate / 60` ran at double speed on a 120 Hz panel.
            let step = PlaybackClock.advance(playhead: playhead, elapsed: elapsed,
                                             rate: rate, duration: duration)
            playhead = step.playhead
            if step.reachedEnd {
                if loops, rate > 0 {
                    playhead = 0
                    seek(to: sourceTime(0))
                } else {
                    pause()
                }
            }

            // **Only where it is actually needed.** Output time is not source time — a trim makes
            // them diverge — so the player still has to be put in the right place, but `rate` is
            // already carrying it forward at the speed the playhead is moving. This fires at a cut
            // and after a stall. Seeking every tick, keyframe-exact, is what no decoder could
            // service, and it is why playback appeared frozen.
            let wanted = sourceTime(playhead)
            if PlaybackClock.needsResync(playerTime: player.currentTime().seconds, wanted: wanted) {
                seek(to: wanted)
            }

            // The soundtrack against the playhead, since it is cut to output time — and on a
            // looser tolerance, because putting audio back is a click rather than a decode.
            if let soundtrackPlayer,
               PlaybackClock.needsResync(playerTime: soundtrackPlayer.currentTime().seconds,
                                         wanted: playhead,
                                         tolerance: PlaybackClock.audioResyncTolerance) {
                seekSoundtrack(to: playhead)
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
