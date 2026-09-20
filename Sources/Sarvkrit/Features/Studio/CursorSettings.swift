import Foundation

/// How the pointer is drawn back into the video.
///
/// Every one of these is a decision made *after* recording, which is only possible because the
/// screen was captured with `showsCursor = false` and the pointer's path was logged instead.
struct CursorSettings: Codable, Equatable {
    var isHidden = false
    /// Multiplier on the glyph, applied in canvas space.
    ///
    /// Canvas space, not screen-layer space, and the difference matters: a cursor that scaled with
    /// the zoom would be comically large at 2.5×. It grows a little with zoom so it does not look
    /// detached, but nowhere near linearly.
    var size: Double = 1.6
    var smoothing: CursorSmoothing = .standard
    var clickEffect: ClickEffectStyle = .ripple
    var playsClickSound = false

    /// Master switch, then the three independent channels.
    ///
    /// Separate because they answer different questions: a blurred cursor over a sharp frame is
    /// right when only the mouse moved, and a blurred frame is right when the zoom raced somewhere.
    /// One slider cannot say both.
    var motionBlur = true
    var motionBlurCursor: Double = 1
    var motionBlurZoom: Double = 1
    var motionBlurPan: Double = 1

    /// Stops a recording that pauses on a diagram having a pointer sitting in the middle of it.
    var hidesWhenIdle = true
    var idleDelay: TimeInterval = 3

    /// For a clip meant to loop: eases the pointer back to where it started.
    var loopsToStart = false
    var loopSeconds: TimeInterval = 1

    /// A few degrees into the direction of travel while moving fast. Felt more than seen.
    var rotatesWhileMoving = true
    /// Filters out macOS's shake-to-locate zigzag.
    var removesShakes = true

    /// Names a `CursorSet`. Held as a string so a set added by a newer build round-trips rather
    /// than being reset to the default on save.
    var setID = "macOS"

    init() {}
}
