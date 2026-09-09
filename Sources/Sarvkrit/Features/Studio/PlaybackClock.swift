import Foundation

/// The arithmetic behind playback, separated from AVFoundation so it can be reasoned about.
///
/// **Both halves of this were wrong, and together they were most of "the editor does not work".**
///
/// The playhead moves in *output* time, which is not source time — a trim makes them diverge — so
/// playback cannot simply read the player's clock. It has to advance the playhead itself and put
/// the player where that lands. The previous version did both badly: it assumed every display-link
/// tick was exactly 1/60 of a second, and it then asked for a keyframe-exact seek on *every* tick,
/// sixty a second, on top of the real-time playback that setting `rate` had already begun.
enum PlaybackClock {

    /// How far the player may drift before it is nudged back, in seconds.
    ///
    /// Large enough that ordinary real-time playback never triggers it — that is the whole point —
    /// and small enough that a cut lands within a couple of frames.
    static let resyncTolerance: TimeInterval = 0.05

    /// The same question for the soundtrack, answered more loosely.
    ///
    /// **Correcting audio drift is audible.** A seek on the video player costs a decode nobody
    /// notices; a seek on the audio player is a click in the middle of a word. So the soundtrack
    /// rides through the drift a frame would be corrected for, and is only put back when it is far
    /// enough out to hear as lip-sync error.
    static let audioResyncTolerance: TimeInterval = 0.25

    struct Step: Equatable {
        var playhead: TimeInterval
        /// True at either end: forwards past the duration, or backwards past zero when shuttling.
        var reachedEnd: Bool
    }

    /// - Parameter elapsed: seconds that actually passed, not an assumed frame interval. A display
    ///   link runs at the screen's refresh rate — 120 Hz is ordinary — and a stalled tick covers
    ///   more than one frame.
    static func advance(playhead: TimeInterval, elapsed: TimeInterval, rate: Float,
                        duration: TimeInterval) -> Step {
        let span = max(0, duration)
        let moved = playhead + elapsed * Double(rate)
        let clamped = min(max(0, moved), span)
        // **Which end depends on which way we are going.** Checking both unconditionally meant the
        // first tick of every playback — elapsed zero, playhead zero — read as having reached the
        // start, and paused before anything moved.
        let reachedEnd = rate < 0 ? moved <= 0 : moved >= span
        return Step(playhead: clamped, reachedEnd: reachedEnd)
    }

    /// Whether the player is far enough from where the project wants it to be worth a seek.
    ///
    /// In continuous playback the answer is no, every time: `rate` is already carrying the player
    /// forward at exactly the speed the playhead is moving. It becomes yes at a cut, where output
    /// time jumps to a different point in the source, and after a stall.
    static func needsResync(playerTime: TimeInterval, wanted: TimeInterval,
                            tolerance: TimeInterval = resyncTolerance) -> Bool {
        abs(playerTime - wanted) > tolerance
    }

    /// Where a moment in the recording lands inside `camera.mov`, or nil when there is no camera
    /// picture for it.
    ///
    /// **The two tracks do not start together.** `AVCaptureSession` takes a couple of seconds to
    /// bring a camera up, so the camera file begins later than the screen and ends sooner. In a
    /// real take here the screen ran 29.175 s against the camera's 26.747 s — a 2.43 s offset.
    /// Reading the camera at the screen's own time would put the face two and a half seconds ahead
    /// of what it is reacting to.
    ///
    /// **Nil before the camera was running — not its first frame held.**
    ///
    /// An earlier version held the first frame through the lead-in, reasoning that an empty bubble
    /// looks like a broken camera. That was the wrong trade: for those couple of seconds there is
    /// no narration either, so a motionless face over silence reads as the recording having
    /// stalled. The camera appears when it actually started, and `CameraLayoutResolver` fades it in
    /// so it does not pop.
    ///
    /// Nil after it stops, too, which is ordinary rather than a failure:
    /// `StudioRenderer.drawCamera` draws nothing when it has no image.
    ///
    /// - Parameter startOffset: seconds by which the camera started after the screen. Zero for
    ///   bundles recorded before that was measured, which then behave exactly as they used to.
    static func cameraTime(forSource source: TimeInterval, startOffset: TimeInterval,
                           cameraDuration: TimeInterval) -> TimeInterval? {
        guard cameraDuration > 0 else { return nil }
        let t = source - startOffset
        guard t >= 0, t < cameraDuration else { return nil }
        return t
    }
}
