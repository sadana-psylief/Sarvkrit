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
        return Step(playhead: clamped, reachedEnd: moved >= span || moved <= 0)
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
    /// Nil at either end is ordinary, not a failure: `StudioRenderer.drawCamera` already draws
    /// nothing when it has no image.
    ///
    /// - Parameter startOffset: seconds by which the camera started after the screen. Zero for
    ///   bundles recorded before that was measured, which then behave exactly as they used to.
    static func cameraTime(forSource source: TimeInterval, startOffset: TimeInterval,
                           cameraDuration: TimeInterval) -> TimeInterval? {
        let t = source - startOffset
        guard t >= 0, t < cameraDuration else { return nil }
        return t
    }
}
